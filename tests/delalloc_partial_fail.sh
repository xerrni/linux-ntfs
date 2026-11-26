# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): what a failed buffered write
# into a hole at an offset that is not cluster aligned leaves allocated.
#
# ->iomap_begin() zeroes the parts of the first and last new cluster that the
# write does not cover, in the page cache, before anything is copied.  When
# the copy then fails (EFAULT here), the delalloc release keeps every cluster
# with a dirty folio, so those zeroed edge clusters stay delalloc and
# writeback allocates them: a sparse file gets up to two clusters of zeroes
# where it had holes.  Writeback also converts a whole delalloc run when it
# writes back part of it (sync_file_range() of the first page here).
# A short copy into a hole whose folio is in the page cache leaves that folio
# with dirty blocks followed by clean ones.  iomap releases the clean blocks
# of a dirty folio one block (512 bytes) at a time, and a delalloc
# reservation is a whole cluster, so with 1 KiB and 2 KiB clusters the
# clusters of that folio that the write did not reach stay reserved unless
# they are released as one range.  The volume first holds a deleted file of
# 0xee, so that a cluster allocated without being written shows old data.
# Checked for each of $CLUSTERS plus 1024 and 2048:
#   - the file reads back as zeroes (or the data written), from the page
#     cache, after dropping it, and after a remount (correctness, FAIL)
#   - at most the two zeroed edge clusters stay allocated (FAIL)
#   - a short copy of one cluster into a hole below the initialized size,
#     read into the page cache first, allocates one cluster (FAIL).  A write
#     that ends above the initialized size drops the page cache before it
#     copies, so only this file has clean cached blocks behind the dirty ones.
#   - a short copy that starts one cluster into such a hole and stops 512
#     bytes into its second cluster allocates those two clusters only: the
#     rest of the second cluster must reach the disk, but the clean blocks
#     around it in the same folio (a hole before the write, an unused
#     reservation after it) must stay clean (FAIL)
#   - with clusters smaller than a page, a write that fails on its first byte
#     over the clean cached blocks of a folio whose last cluster is dirty
#     reserves nothing (FAIL)
#   - ntfsck -n is clean.
. "$HARNESS/guest_lib.sh"
mountpoint -q /mnt || mount -t tmpfs -o size=1g tmpfs /mnt
IMG=/mnt/partial-fail.img
efault() {	# efault FILE OFFSET LENGTH: pwrite() from an unmapped buffer
	python3 - "$@" <<'PY'
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
libc.pwrite.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_long]
fd = os.open(sys.argv[1], os.O_WRONLY)
r = libc.pwrite(fd, 4096, int(sys.argv[3]), int(sys.argv[2]))
print("pwrite from a bad buffer:", r, os.strerror(ctypes.get_errno()))
PY
}
shortcopy() {	# shortcopy FILE OFFSET LENGTH [VALID]: pwrite() whose source faults after VALID (512) bytes
	python3 - "$@" <<'PY'
import ctypes, mmap, os, sys
libc = ctypes.CDLL(None, use_errno=True)
libc.mmap.restype = ctypes.c_void_p
libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int,
                      ctypes.c_int, ctypes.c_long]
libc.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
libc.pwrite.restype = ctypes.c_ssize_t
libc.pwrite.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_long]
pg = mmap.PAGESIZE
off, n = int(sys.argv[2]), int(sys.argv[3])
valid = int(sys.argv[4]) if len(sys.argv) > 4 else 512
size = -(-valid // pg) * pg
buf = libc.mmap(None, size + pg, mmap.PROT_READ | mmap.PROT_WRITE,
                mmap.MAP_PRIVATE | mmap.MAP_ANONYMOUS, -1, 0)
libc.munmap(buf + size, pg)
src = buf + size - valid
ctypes.memset(src, 0xab, valid)
fd = os.open(sys.argv[1], os.O_RDWR)
os.pread(fd, n, off)	# the hole's folios become uptodate, so a short copy counts
r = libc.pwrite(fd, src, n, off)
print("pwrite whose source faults after %d bytes:" % valid, r)
sys.exit(r != valid)
PY
}
zeroes() {	# zeroes FILE SIZE [OFF LEN BYTE]...: contents check
	python3 - "$@" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
exp = bytearray(int(sys.argv[2]))
for k in range(3, len(sys.argv), 3):
    o, n, b = int(sys.argv[k]), int(sys.argv[k + 1]), int(sys.argv[k + 2], 0)
    exp[o:o + n] = bytes([b]) * n
if bytes(exp) != d:
    bad = [i for i in range(min(len(d), len(exp))) if d[i] != exp[i]]
    sys.exit("differs at %d (size %d): %d wrong bytes in [%d, %d), values %s" % (
        bad[0] if bad else -1, len(d), len(bad), bad[0] if bad else -1,
        bad[-1] + 1 if bad else -1, sorted({hex(d[i]) for i in bad})[:4]))
PY
}
for cs in $(echo "$CLUSTERS 1024 2048" | tr ' ' '\n' | sort -nu); do
	rm -f $IMG; truncate -s 64M $IMG
	mkntfs -F -Q -q -c "$cs" $IMG >/dev/null 2>&1 || { fail "mkntfs c$cs"; continue; }
	mount -i -t ntfs -o loop $IMG "$M" || { fail "mount c$cs"; continue; }
	python3 -c "import sys; sys.stdout.buffer.write(b'\xee' * (16 << 20))" > "$M"/old
	sync; rm "$M"/old; sync
	unit=$((cs > 4096 ? cs : 4096))
	size=$((64 * unit))
	for init in 0 full; do
		tag="failed unaligned write init=$init c$cs"; mark "$tag"
		f=$M/f-$init
		xfs_io -f -c "truncate $size" "$f"
		[ $init = full ] && xfs_io -c "pwrite -q $((size - 512)) 512" "$f"
		xfs_io -c fsync "$f"; sync
		free0=$(stat -f -c %f "$M")
		efault "$f" $((8 * unit + 512)) $((8 * unit))
		sync
		free1=$(stat -f -c %f "$M")
		exp=(); [ $init = full ] && exp=($((size - 512)) 512 0xcd)
		if zeroes "$f" $size "${exp[@]}"; then echo "PASS: $tag contents (cache)"; else fail "$tag contents (cache)"; fi
		echo 3 > /proc/sys/vm/drop_caches
		if zeroes "$f" $size "${exp[@]}"; then echo "PASS: $tag contents (disk)"; else fail "$tag contents (disk)"; fi
		echo "$tag: $((free0 - free1)) clusters allocated by the failed write"
		if [ $((free0 - free1)) -le 2 ]; then
			echo "PASS: $tag allocates at most the zeroed edge clusters"
		else
			fail "$tag: $((free0 - free1)) clusters allocated, at most 2 expected"
		fi
	done
	tag="short copy of one cluster into a cached hole c$cs"; mark "$tag"
	f=$M/short-cs
	exp_cs=(0 "$cs" 0xab $((size - 512)) 512 0xcd)
	xfs_io -f -c "truncate $size" -c "pwrite -q $((size - 512)) 512" -c fsync "$f"; sync
	free0=$(stat -f -c %f "$M")
	shortcopy "$f" 0 $((8 * unit)) "$cs" || fail "$tag: the write was not $cs bytes"
	sync
	free1=$(stat -f -c %f "$M")
	if zeroes "$f" $size "${exp_cs[@]}"; then echo "PASS: $tag contents (cache)"; else fail "$tag contents (cache)"; fi
	echo 3 > /proc/sys/vm/drop_caches
	if zeroes "$f" $size "${exp_cs[@]}"; then echo "PASS: $tag contents (disk)"; else fail "$tag contents (disk)"; fi
	echo "$tag: $((free0 - free1)) clusters allocated or reserved by the short write"
	if [ $((free0 - free1)) -le 1 ]; then
		echo "PASS: $tag keeps only the cluster written"
	else
		fail "$tag: $((free0 - free1)) clusters allocated or reserved, 1 expected"
	fi
	tag="short copy ending inside a cluster of a cached hole c$cs"; mark "$tag"
	f=$M/short-tail
	exp_tail=("$cs" $((cs + 512)) 0xab $((size - 512)) 512 0xcd)
	xfs_io -f -c "truncate $size" -c "pwrite -q $((size - 512)) 512" -c fsync "$f"; sync
	free0=$(stat -f -c %f "$M")
	shortcopy "$f" "$cs" $((8 * unit)) $((cs + 512)) || fail "$tag: the write was not $((cs + 512)) bytes"
	sync
	free1=$(stat -f -c %f "$M")
	if zeroes "$f" $size "${exp_tail[@]}"; then echo "PASS: $tag contents (cache)"; else fail "$tag contents (cache)"; fi
	echo 3 > /proc/sys/vm/drop_caches
	if zeroes "$f" $size "${exp_tail[@]}"; then echo "PASS: $tag contents (disk)"; else fail "$tag contents (disk)"; fi
	echo "$tag: $((free0 - free1)) clusters allocated or reserved by the short write"
	if [ $((free0 - free1)) -le 2 ]; then
		echo "PASS: $tag keeps only the two clusters written"
	else
		fail "$tag: $((free0 - free1)) clusters allocated or reserved, 2 expected"
	fi
	if [ "$cs" -lt 4096 ]; then
		tag="failed write over clean blocks of a dirty folio c$cs"; mark "$tag"
		f=$M/dirty
		exp_dirty=($((4096 - cs)) "$cs" 0x5a $((size - 512)) 512 0xcd)
		xfs_io -f -c "truncate $size" -c "pwrite -q $((size - 512)) 512" -c fsync "$f"; sync
		free0=$(stat -f -c %f "$M")
		xfs_io -c "pread -q 0 4096" -c "pwrite -q -S 0x5a $((4096 - cs)) $cs" "$f"
		efault "$f" 0 $((4096 - cs))
		sync
		free1=$(stat -f -c %f "$M")
		if zeroes "$f" $size "${exp_dirty[@]}"; then echo "PASS: $tag contents (cache)"; else fail "$tag contents (cache)"; fi
		echo 3 > /proc/sys/vm/drop_caches
		if zeroes "$f" $size "${exp_dirty[@]}"; then echo "PASS: $tag contents (disk)"; else fail "$tag contents (disk)"; fi
		echo "$tag: $((free0 - free1)) clusters allocated or reserved by the two writes"
		if [ $((free0 - free1)) -le 1 ]; then
			echo "PASS: $tag keeps only the cluster written"
		else
			fail "$tag: $((free0 - free1)) clusters allocated or reserved, 1 expected"
		fi
	fi
	tag="partial writeback c$cs"; mark "$tag"
	f=$M/run
	xfs_io -f -c "pwrite -q -S 0x42 0 $((16 * unit))" "$f"
	b0=$(stat -c %b "$f")
	xfs_io -c "sync_range -b -w -a 0 4096" "$f"
	echo "$tag: st_blocks $b0 -> $(stat -c %b "$f"); extents after writeback of the first page:"
	xfs_io -c "fiemap -v" "$f" | sed -n '3,6p'
	umount "$M"
	mount -i -t ntfs -o loop $IMG "$M" || { fail "remount c$cs"; continue; }
	if zeroes "$M"/f-0 $size && zeroes "$M"/f-full $size $((size - 512)) 512 0xcd; then
		echo "PASS: contents after remount c$cs"
	else
		fail "contents after remount c$cs"
	fi
	if zeroes "$M"/short-cs $size "${exp_cs[@]}" && zeroes "$M"/short-tail $size "${exp_tail[@]}" && { [ "$cs" -ge 4096 ] || zeroes "$M"/dirty $size "${exp_dirty[@]}"; }; then
		echo "PASS: cached hole contents after remount c$cs"
	else
		fail "cached hole contents after remount c$cs"
	fi
	if python3 -c "import sys; d=open(sys.argv[1],'rb').read(); sys.exit(d != b'\x42'*len(d))" "$f"; then
		echo "PASS: $tag contents"
	else
		fail "$tag contents"
	fi
	umount "$M"
	run_ntfsck $IMG "partial-c$cs"
done
rm -f $IMG
dmesg_check
echo "### done"
