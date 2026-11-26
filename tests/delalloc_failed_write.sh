# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): a buffered write into a hole that
# fails (here: EFAULT from a bad user buffer) after ->iomap_begin() reserved
# delayed allocation for it.
#
# ->iomap_begin() turns the hole into an LCN_DELALLOC run and reserves its
# clusters; with nothing copied there is no dirty folio, so writeback never
# allocates the run and the reservation stays until the inode is evicted.  The
# stale run also reaches code that never expects delalloc runs after a flush:
# FALLOC_FL_PUNCH_HOLE / COLLAPSE_RANGE split runs with "lcn > LCN_HOLE"
# checks that take LCN_DELALLOC (-1) for a real cluster number and shift it,
# so the split-off part of the run points at real clusters of other files.
# For each of $CLUSTERS, on a fresh volume, a sparse 1 MiB-equivalent file
# gets a failed write over its first half and then
#   none     nothing: statfs after sync must match a fresh mount (no leak)
#   punch    a punched hole that splits the stale run
#   collapse a collapsed range that splits the stale run
#   insert   an inserted range that splits the stale run
#   write    a successful write into the middle of the stale run
# and must read back as zeros (or the written data), with ntfsck -n clean.
. "$HARNESS/guest_lib.sh"
mountpoint -q /mnt || mount -t tmpfs -o size=1g tmpfs /mnt
IMG=/mnt/failed-write.img
for cs in $CLUSTERS; do
	unit=$((cs > 4096 ? cs : 4096))
	big=$((256 * unit))
	for case in none punch collapse insert write; do
		tag="failed write + $case c$cs"
		mark "$tag"
		rm -f $IMG; truncate -s 64M $IMG
		mkntfs -F -Q -q -c "$cs" $IMG >/dev/null 2>&1 || { fail "$tag mkntfs"; continue; }
		mount -i -t ntfs -o loop $IMG "$M" || { fail "$tag mount"; continue; }
		# some metadata and data around so that bogus cluster numbers hit something
		for i in 1 2 3 4; do xfs_io -f -c "pwrite -q -S 0x3$i 0 $((8 * unit))" "$M"/other$i; done
		f=$M/f
		xfs_io -f -c "truncate $big" -c fsync "$f"
		sync
		free0=$(stat -f -c %f "$M")
		python3 - "$f" $((big / 2)) <<'PY' || fail "$tag: write from a bad buffer did not fail"
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
libc.pwrite.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_long]
fd = os.open(sys.argv[1], os.O_WRONLY)
r = libc.pwrite(fd, 4096, int(sys.argv[2]), 0)	# unmapped user address
print("pwrite from a bad buffer:", r, os.strerror(ctypes.get_errno()))
sys.exit(0 if r < 0 else 1)
PY
		size=$big; wr=""
		case $case in
		punch)	xfs_io -c "fpunch $((big / 8)) $((big / 8))" "$f" || fail "$tag fpunch" ;;
		collapse) xfs_io -c "fcollapse $((big / 8)) $((big / 8))" "$f" || fail "$tag fcollapse"
			size=$((big - big / 8)) ;;
		insert)	xfs_io -c "finsert $((big / 8)) $((big / 8))" "$f" || fail "$tag finsert"
			size=$((big + big / 8)) ;;
		write)	xfs_io -c "pwrite -q -S 0x77 $((big / 8)) $unit" "$f"; wr=$((big / 8)) ;;
		esac
		sync
		free1=$(stat -f -c %f "$M")
		echo 3 > /proc/sys/vm/drop_caches
		if python3 - "$f" $size "$wr" $unit <<'PY'; then echo "PASS: $tag contents"; else fail "$tag contents"; fi
import sys
d = open(sys.argv[1], "rb").read()
size, wr, unit = int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
exp = bytearray(size)
if wr:
    exp[int(wr):int(wr) + unit] = b"\x77" * unit
if len(d) != size:
    sys.exit(f"size {len(d)} != {size}")
if d != exp:
    i = next(i for i in range(size) if d[i] != exp[i])
    sys.exit(f"differs at {i}: {d[i:i + 16].hex()} (FILE record: {b'FILE' in d})")
PY
		umount "$M"
		run_ntfsck $IMG "failed-$case-c$cs"
		mount -i -t ntfs -o loop $IMG "$M"
		free2=$(stat -f -c %f "$M")
		umount "$M"
		if [ "$case" = none ] || [ "$case" = punch ]; then
			# nothing was allocated: all clusters must be free again
			if [ "$free1" = "$free0" ] && [ "$free2" = "$free0" ]; then
				echo "PASS: $tag free space ($free0)"
			else
				fail "$tag free space: before $free0, after sync $free1, after remount $free2"
			fi
		else
			if [ "$free1" = "$free2" ]; then
				echo "PASS: $tag no leak ($free1)"
			else
				fail "$tag: leak $((free2 - free1)) clusters (after sync $free1, after remount $free2)"
			fi
		fi
	done
done
rm -f $IMG
dmesg_check
echo "### done"
