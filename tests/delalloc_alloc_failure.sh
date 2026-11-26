# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): a cluster allocation that fails
# with ENOMEM must not drop the delalloc reservations of other files.
#
# ntfs_cluster_alloc() reset vol->dirty_clusters to 0 on every failure after
# its free space check (only -ENOMEM and -EIO get there).  That drops the
# reservation of every file with delayed data: statfs() reports the reserved
# clusters as free again, new buffered writes are accepted for them, and
# writeback of the delayed data then runs out of space and loses it.
# For each of $CLUSTERS, on a fresh volume:
#   - write file A (4 MiB) without syncing, so it holds a delalloc reservation
#   - create small files B and fsync each with /proc/thread-self/fail-nth set
#     to 1, 2, 3, ... until an injected allocation failure makes
#     ntfs_cluster_alloc() fail ("Failed to allocate clusters ... -12")
#   - check that statfs() free space did not rise by A's reservation
#   - go on with every fault site the fsync reaches: a failed fsync must not
#     change the free space (B keeps its reservation) or B's st_blocks
#   - write a file that takes all the free space statfs() reports, sync, and
#     check that A and that file read back after a remount.
# Needs CONFIG_FAULT_INJECTION, FAILSLAB, FAIL_PAGE_ALLOC and
# FAULT_INJECTION_DEBUG_FS (the "debug" flavour of build_kernel.sh).
. "$HARNESS/guest_lib.sh"
mountpoint -q /mnt || mount -t tmpfs -o size=1g tmpfs /mnt
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
for f in failslab fail_page_alloc; do
	echo N > /sys/kernel/debug/$f/ignore-gfp-wait
	echo "${FAULT_VERBOSE:-1}" > /sys/kernel/debug/$f/verbose
done
echo 0 > /sys/kernel/debug/fail_page_alloc/min-order
IMG=/mnt/allocfail.img
for cs in $CLUSTERS; do
	tag="alloc failure c$cs"
	mark "$tag"
	rm -f $IMG; truncate -s 128M $IMG
	mkntfs -F -Q -q -c "$cs" $IMG >/dev/null 2>&1 || { fail "$tag mkntfs"; continue; }
	mount -i -t ntfs -o loop $IMG "$M" || { fail "$tag mount"; continue; }
	unit=$((cs > 4096 ? cs : 4096))
	sync
	free0=$(stat -f -c %f "$M")
	xfs_io -f -c "pwrite -q -S 0x5a 0 4m" "$M"/A
	free1=$(stat -f -c %f "$M")
	resv=$((free0 - free1))
	echo "A reserved $resv clusters (free $free0 -> $free1)"
	sleep 6	# kernel messages are rate limited (10 per 5 s); the scan needs them
	python3 - "$M" $unit > "$W"/scan.txt <<'PY'
import os, subprocess, sys
mnt, unit = sys.argv[1], int(sys.argv[2])
MSG = "Failed to allocate clusters, aborting (error -12)"
def kmsg_count():
    return subprocess.run(["dmesg"], capture_output=True, text=True).stdout.count(MSG)
NTH = os.open("/proc/thread-self/fail-nth", os.O_RDWR)
def nth(v=None):
    if v is not None:
        os.pwrite(NTH, str(v).encode(), 0)
        return
    try:
        return int(os.pread(NTH, 32, 0).strip() or 0)
    except OSError:	# the fault fired here, so the fsync did not reach it
        return 1
seen = kmsg_count()
hit = 0
for n in range(1, 400):
    p = os.path.join(mnt, "B%d" % n)
    fd = os.open(p, os.O_CREAT | os.O_WRONLY, 0o644)
    os.write(fd, b"\x33" * unit)
    before, b1 = os.statvfs(mnt).f_bfree, os.fstat(fd).st_blocks
    nth(n)
    try:
        os.fsync(fd)
        r = 0
    except OSError as e:
        r = -e.errno
    left = nth()
    nth(0)
    after, b2 = os.statvfs(mnt).f_bfree, os.fstat(fd).st_blocks
    os.close(fd)
    os.unlink(p)
    if left:	# n is past the last fault site of the fsync
        break
    if not hit and kmsg_count() > seen:
        hit = n
        print("HIT", n, r, before, after)
    if r and after != before:
        print("DELTA", n, r, after - before)
    if r and b2 != b1:
        print("BLOCKS", n, r, b1, b2)
print("END", n - 1)
PY
	dmesg > "$W"/dmesg-c"$cs".txt
	grep -v "^DELTA\|^BLOCKS" "$W"/scan.txt
	read -ra hit < <(grep ^HIT "$W"/scan.txt)
	set -- "${hit[@]}"
	if [ $# = 0 ]; then
		fail "$tag: no injected failure reached ntfs_cluster_alloc()"
		umount "$M"; continue
	fi
	n=$2 r=$3 before=$4 after=$5
	echo "fail-nth $n: fsync returned $r, free clusters $before -> $after"
	if [ $((after - before)) -ge $((resv / 2)) ]; then
		fail "$tag: free space rose by $((after - before)) clusters after the failed allocation (A holds $resv)"
	else
		echo "PASS: $tag reservation kept"
	fi
	# every failed fsync of B must leave B's reservation and st_blocks alone
	if grep -q ^DELTA "$W"/scan.txt; then
		fail "$tag: a failed fsync changed the free space"
		grep ^DELTA "$W"/scan.txt | head -5
	else
		echo "PASS: $tag free space unchanged by every failed fsync"
	fi
	if grep -q ^BLOCKS "$W"/scan.txt; then
		fail "$tag: a failed fsync changed st_blocks"
		grep ^BLOCKS "$W"/scan.txt | head -5
	else
		echo "PASS: $tag st_blocks unchanged by every failed fsync"
	fi
	after=$(stat -f -c %f "$M")
	# take everything statfs() calls free, keeping 16 clusters for metadata
	fill=$(( (after - 16) * cs ))
	r=$(python3 - "$M"/fill $fill <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
n, off, chunk = int(sys.argv[2]), 0, 1 << 20
try:
    while off < n:
        off += os.write(fd, b"\x77" * min(chunk, n - off))
except OSError as e:
    print("write error", e.errno, "at", off)
os.close(fd)
print(off)
PY
)
	echo "fill wrote $r of $fill bytes"
	sync
	umount "$M"
	mount -i -t ntfs -o loop $IMG "$M" || { fail "$tag remount"; continue; }
	if python3 - "$M" <<'PY'; then echo "PASS: $tag data"; else fail "$tag data lost"; fi
import os, sys
m = sys.argv[1]
a = open(os.path.join(m, "A"), "rb").read()
assert len(a) == 4 << 20 and a == b"\x5a" * len(a), "A: %d bad bytes" % sum(1 for x in a if x != 0x5a)
f = open(os.path.join(m, "fill"), "rb").read()
bad = len(f) - f.count(b"\x77")
assert bad == 0, "fill: %d of %d bytes are not the written data" % (bad, len(f))
PY
	umount "$M"
	run_ntfsck $IMG "allocfail-c$cs"
done
rm -f $IMG
DMESG_IGNORE="${DMESG_IGNORE:+$DMESG_IGNORE|}FAULT_INJECTION" dmesg_check
echo "### done"
