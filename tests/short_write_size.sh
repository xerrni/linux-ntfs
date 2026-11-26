# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): a buffered write that runs out
# of space part way must not leave the file size past the bytes it wrote.
#
# ntfs_file_write_iter() extends data_size/i_size to pos + count before it
# copies anything (ntfs_expand_for_write()).  When the delayed allocation then
# runs out of free clusters after the first iteration, the write returns a short
# count, and the size must be rolled back to pos + written (as on ext4/xfs):
# otherwise the file grows by a tail of zeros that was never written, which a
# caller that checks the return value cannot know about.
# For each of $CLUSTERS: fill a fresh volume with fallocate() until only a few
# clusters are free, append 32 clusters to a non-resident file, and check
#   - the write returned a short count (or ENOSPC)
#   - st_size == old size + returned count, also after a remount
#   - the bytes written are there; ntfsck -n is clean.
. "$HARNESS/guest_lib.sh"
mountpoint -q /mnt || mount -t tmpfs -o size=1g tmpfs /mnt
IMG=/mnt/short.img
for cs in $CLUSTERS; do
	tag="short write c$cs"
	mark "$tag"
	rm -f $IMG; truncate -s 64M $IMG
	mkntfs -F -Q -q -c "$cs" $IMG >/dev/null 2>&1 || { fail "$tag mkntfs"; continue; }
	mount -i -t ntfs -o loop $IMG "$M" || { fail "$tag mount"; continue; }
	unit=$((cs > 4096 ? cs : 4096))
	xfs_io -f -c "pwrite -q -S 0x11 0 $((4 * unit))" -c fsync "$M"/f
	sync
	free=$(stat -f -c %f "$M")
	keep=$((4 * unit / cs))		# clusters left free
	xfs_io -f -c "falloc 0 $(((free - keep) * cs))" "$M"/fill || fail "$tag fill"
	sync
	echo "free clusters: $(stat -f -c %f "$M") (wanted $keep)"
	# append 32 units in one write(2); report the return value and the size
	out=$(python3 - "$M"/f $((4 * unit)) $((32 * unit)) <<'PY'
import os, sys
path, off, n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
fd = os.open(path, os.O_WRONLY)
try:
    r = os.pwrite(fd, b"\x22" * n, off)
except OSError as e:
    r = -e.errno
os.close(fd)
print(r, os.stat(path).st_size)
PY
)
	read -r ret size <<< "$out"
	old=$((4 * unit))
	echo "write of $((32 * unit)) at $old returned $ret, size $size"
	if [ "$ret" -ge $((32 * unit)) ]; then
		fail "$tag: the write did not run out of space (ret $ret), test setup broken"
	elif [ "$ret" -lt 0 ] && [ "$size" != $old ]; then
		fail "$tag: failed write changed the size $old -> $size"
	elif [ "$ret" -ge 0 ] && [ "$size" != $((old + ret)) ]; then
		fail "$tag: size $size after a short write of $ret bytes at $old (expected $((old + ret)))"
	else
		echo "PASS: $tag size"
	fi
	umount "$M"; mount -i -t ntfs -o loop $IMG "$M"
	size2=$(stat -c %s "$M"/f)
	[ "$size2" = "$size" ] || fail "$tag: size $size2 after remount, $size before"
	if python3 - "$M"/f $old <<'PY'; then echo "PASS: $tag data"; else fail "$tag data"; fi
import sys
d = open(sys.argv[1], "rb").read()
old = int(sys.argv[2])
assert d[:old] == b"\x11" * old, "old data changed"
tail = d[old:].rstrip(b"\0")
assert tail == b"\x22" * len(tail), "written data corrupt"
PY
	umount "$M"
	run_ntfsck $IMG "short-c$cs"
done
rm -f $IMG
dmesg_check
echo "### done"
