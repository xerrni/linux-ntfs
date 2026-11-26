# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): compressed writes must respect
# the delalloc reservations of other files, and a compressed write that fails
# must leave the old compression block in place.
#
#   resv   ntfs_cb_cluster_alloc() called ntfs_cluster_alloc() with
#          is_dealloc set, as if the compressed write had reserved delayed
#          allocation: the allocation skipped the check against
#          vol->dirty_clusters and released other files' reservations.  A
#          buffered write (file A, not synced) takes all but 16 clusters of
#          the free space; a 512 KiB incompressible write into a compressed
#          file must then fail (ENOSPC or a short write), and A must read back
#          after sync and a remount.
#   fault  ntfs_write_cb() punched the old compression block, then merged the
#          new one into the runlist and wrote the mapping pairs; a failure
#          after the punch lost the block.  Overwrite 64 KiB (one compression
#          block with 4 KiB clusters, eight with 512 B clusters) with
#          /proc/thread-self/fail-nth set to 1, 2, 3, ... (every fault site
#          of the write): after each attempt, with the page cache dropped,
#          every compression block must hold its new data if the write
#          succeeded and its old or new data if it failed; also after a
#          remount.
# Needs the "debug" flavour of build_kernel.sh (fault injection).  Cluster
# sizes: $COMP_CLUSTERS (default "512 4096"; compression needs <= 4 KiB).
. "$HARNESS/guest_lib.sh"
mountpoint -q /mnt || mount -t tmpfs -o size=1g tmpfs /mnt
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
for f in failslab fail_page_alloc; do
	echo N > /sys/kernel/debug/$f/ignore-gfp-wait
	echo 0 > /sys/kernel/debug/$f/verbose
done
echo 0 > /sys/kernel/debug/fail_page_alloc/min-order
IMG=/mnt/cwerr.img
mkcomp() {	# mkcomp PATH: empty file marked compressed
	touch "$1" && setfattr -h -v 0x00000800 -n system.ntfs_attrib_be "$1"
}
for cs in ${COMP_CLUSTERS:-512 4096}; do
	tag="compressed resv c$cs"
	mark "$tag"
	rm -f $IMG; truncate -s 64M $IMG
	mkntfs -F -Q -q -c "$cs" $IMG >/dev/null 2>&1 || { fail "$tag mkntfs"; continue; }
	mount -i -t ntfs -o loop $IMG "$M" || { fail "$tag mount"; continue; }
	mkcomp "$M"/C || { fail "$tag set compressed"; umount "$M"; continue; }
	sync
	free=$(stat -f -c %f "$M")
	asize=$(( (free - 16) * cs / 4096 * 4096 ))
	xfs_io -f -c "pwrite -q -S 0x5a 0 $asize" "$M"/A
	echo "free $free clusters, A reserves $asize bytes, statfs free now $(stat -f -c %f "$M")"
	r=$(python3 - "$M"/C <<'PY'
import os, random, sys
random.seed(1)
data = bytes(random.getrandbits(8) for _ in range(512 << 10))
fd = os.open(sys.argv[1], os.O_WRONLY)
try:
    r = os.pwrite(fd, data, 0)
except OSError as e:
    r = -e.errno
os.close(fd)
print(r)
PY
)
	echo "compressed write of 524288 bytes returned $r, statfs free $(stat -f -c %f "$M")"
	sync
	umount "$M"
	mount -i -t ntfs -o loop $IMG "$M" || { fail "$tag remount"; continue; }
	if python3 - "$M" $asize "$r" <<'PY'; then echo "PASS: $tag"; else fail "$tag"; fi
import os, random, sys
m, asize, r = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
a = open(os.path.join(m, "A"), "rb").read()
bad = len(a) - a.count(b"\x5a")
assert len(a) == asize and bad == 0, "A: %d of %d bytes lost" % (bad, asize)
random.seed(1)
data = bytes(random.getrandbits(8) for _ in range(512 << 10))
c = open(os.path.join(m, "C"), "rb").read()
n = max(r, 0)
assert c[:n] == data[:n], "C: written data does not read back"
assert r < len(data), "C: the write took clusters reserved for A"
PY
	umount "$M"
	run_ntfsck $IMG "cw-resv-c$cs"

	tag="compressed fault c$cs"
	mark "$tag"
	rm -f $IMG; truncate -s 64M $IMG
	mkntfs -F -Q -q -c "$cs" $IMG >/dev/null 2>&1 || { fail "$tag mkntfs"; continue; }
	mount -i -t ntfs -o loop $IMG "$M" || { fail "$tag mount"; continue; }
	mkcomp "$M"/C || { fail "$tag set compressed"; umount "$M"; continue; }
	python3 - "$M"/C "$W"/cw-expect "$cs" > "$W"/cw-scan.txt <<'PY'
import os, sys
p = sys.argv[1]
CB = 64 << 10		# the write: one compression block with 4 KiB clusters
UNIT = 16 * int(sys.argv[3])	# compression block: 16 clusters
def text(seed, n):
    out, i = [], 0
    while sum(map(len, out)) < n:
        out.append(("v%d line %d of the compressed file\n" % (seed, i)).encode())
        i += 1
    return b"".join(out)[:n]
expect = bytearray(text(0, 4 * CB))
fd = os.open(p, os.O_WRONLY)
os.pwrite(fd, bytes(expect), 0)
os.fsync(fd)
os.close(fd)
NTH = os.open("/proc/thread-self/fail-nth", os.O_RDWR)
def disk():
    with open("/proc/sys/vm/drop_caches", "w") as f:
        f.write("3")
    return open(p, "rb").read()
bad = new_on_error = 0
for n in range(1, 1000):
    new = text(n, CB)
    fd = os.open(p, os.O_WRONLY)
    os.pwrite(NTH, str(n).encode(), 0)
    try:
        r = os.pwrite(fd, new, CB)
    except OSError as e:
        r = -e.errno
    try:
        left = int(os.pread(NTH, 32, 0).strip() or 0)
    except OSError:
        left = 1
    os.pwrite(NTH, b"0", 0)
    os.close(fd)
    d = disk()
    old = bytes(expect)
    if r > 0:
        expect[CB:CB + r] = new[:r]
    # every compression block holds either its old or its new data
    mixed = d[:CB] == old[:CB] and d[2 * CB:] == old[2 * CB:] and len(d) == len(old) and \
        all(d[o:o + UNIT] in (old[o:o + UNIT], new[o - CB:o - CB + UNIT])
            for o in range(CB, 2 * CB, UNIT))
    if d == bytes(expect):
        pass
    elif r < 0 and mixed:
        # blocks were replaced although the write reported an error
        new_on_error += 1
        expect = bytearray(d)
    else:
        blk = d[CB:2 * CB]
        what = "zeroes" if blk == bytes(len(blk)) else "other data"
        for o in range(CB, 2 * CB, UNIT):
            if d[o:o + UNIT] not in (old[o:o + UNIT], new[o - CB:o - CB + UNIT]):
                z = d[o:o + UNIT] == bytes(UNIT)
                what = "%s at %d" % ("zeroes" if z else "other data", o)
                break
        print("BAD", n, "write returned", r, "block holds", what, "size", len(d))
        bad += 1
        expect = bytearray(d)
    if left:
        break
print("new data after a failed write:", new_on_error)
print("END", n - 1, "sites", bad, "bad")
with open(sys.argv[2], "wb") as f:
    f.write(bytes(expect))
PY
	cat "$W"/cw-scan.txt | head -20
	umount "$M"
	mount -i -t ntfs -o loop $IMG "$M" || { fail "$tag remount"; continue; }
	if ! grep -q "^END" "$W"/cw-scan.txt; then
		fail "$tag: scan did not finish"
	elif grep -q "^BAD" "$W"/cw-scan.txt; then
		fail "$tag: a failed write lost or changed the compression block"
	elif ! cmp -s "$M"/C "$W"/cw-expect; then
		fail "$tag: contents differ after remount"
	else
		echo "PASS: $tag"
	fi
	umount "$M"
	run_ntfsck $IMG "cw-fault-c$cs"
done
rm -f $IMG "$W"/cw-expect
dmesg_check
echo "### done"
