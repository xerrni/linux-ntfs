# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): delayed-allocation free-space
# accounting of the kernel ntfs driver.
#
# statfs() on fs/ntfs reports vol->free_clusters - vol->dirty_clusters, where
# dirty_clusters are the clusters reserved by buffered writes into holes
# (LCN_DELALLOC runs) that writeback has not allocated yet.  Once everything is
# written back (sync) no reservation may be left, so f_bfree must equal the
# number of clear bits in $Bitmap, i.e. what a fresh mount reports.  Each case
# below runs on a fresh volume for each of $CLUSTERS and checks
#   after sync:   f_bfree == f_bfree after umount + mount (no leaked reservation)
#   reservation:  while a write is dirty, f_bfree drops by its clusters and a
#                 fallocate() elsewhere does not give that reservation back
# and that ntfsck -n is clean.  Cases:
#   trunc   buffered write, then truncate down while the pages are still dirty
#           (the delalloc runs past the new EOF are dropped)
#   trunc0  the same, truncate to 0 (attribute becomes resident)
#   punch   PUNCH_HOLE|KEEP_SIZE over dirty delalloc data
#   rewrite overwrite of dirty delalloc data, then sync
#   unlink  unlink of a file with dirty delalloc data, then sync
#   otrunc  files recreated over and over with open(O_TRUNC) + write + append
#           while their data is still delayed (the pattern of the online-defrag
#           load test that ran into ENOSPC within seconds), then unlinked
#   falloc  fallocate() of a second file while the first one holds a
#           reservation
#   srm     removal of a named stream (streams_interface=windows) with dirty
#           delalloc data
#   sunlink unlink of a file whose named stream has dirty delalloc data
#   efault  write(2) into a hole from a buffer that faults (EFAULT): the
#           reservation made by ->iomap_begin() must not outlive the failed
#           write
# A failure prints the leak in clusters ("leak N").
. "$HARNESS/guest_lib.sh"
mountpoint -q /mnt || mount -t tmpfs -o size=1g tmpfs /mnt
IMG=/mnt/delalloc.img
XIO="xfs_io -f"
bfree() { sync; stat -f -c %f "$M"; }
remount_free() {	# fresh count from $Bitmap
	umount "$M" || return 1
	mount -i -t ntfs -o loop,streams_interface=windows $IMG "$M" || return 1
	stat -f -c %f "$M"
}
newvol() {	# newvol CLUSTER
	rm -f $IMG; truncate -s 64M $IMG
	mkntfs -F -Q -q -c "$1" $IMG >/dev/null 2>&1 &&
		mount -i -t ntfs -o loop,streams_interface=windows $IMG "$M"
}
check_leak() {	# check_leak TAG: f_bfree after sync must equal a fresh mount's
	local a b
	a=$(bfree); b=$(remount_free) || { fail "$1 remount"; return; }
	if [ "$a" = "$b" ]; then echo "PASS: $1 (free $a)"
	else fail "$1: leak $((b - a)) clusters (statfs after sync $a, after remount $b)"; fi
}
for cs in $CLUSTERS; do
	unit=$((cs > 4096 ? cs : 4096))
	big=$((256 * unit))		# 1 MiB with 4 KiB clusters
	for case in trunc trunc0 punch rewrite unlink otrunc falloc srm sunlink efault; do
		tag="$case c$cs"
		mark "$tag"
		newvol "$cs" || { fail "$tag mkntfs/mount"; continue; }
		f=$M/f
		case $case in
		trunc)	$XIO -c "pwrite -q -S 0x5a 0 $big" -c "truncate $((big / 4 + 100))" "$f" ;;
		trunc0)	$XIO -c "pwrite -q -S 0x5a 0 $big" -c "truncate 0" "$f" ;;
		punch)	$XIO -c "pwrite -q -S 0x5a 0 $big" \
			     -c "fpunch $((big / 4)) $((big / 2))" "$f" ;;
		rewrite) $XIO -c "pwrite -q -S 0x5a 0 $big" -c "pwrite -q -S 0x6b 0 $big" \
			     -c "pwrite -q -S 0x7c $((big / 2)) $big" "$f" ;;
		unlink)	$XIO -c "pwrite -q -S 0x5a 0 $big" "$f"; rm -f "$f" ;;
		otrunc)	python3 - "$M" $unit <<'PY'
import os, sys
d, unit = sys.argv[1], int(sys.argv[2])
for i in range(300):
    p = os.path.join(d, f"o{i % 3}")
    with open(p, "wb") as f:                    # O_TRUNC of delayed data
        f.write(os.urandom(unit * (1 + i % 7)))
    with open(p, "ab") as f:
        f.write(os.urandom(unit // 2))
    if i % 5 == 4:
        os.unlink(p)
PY
			;;
		falloc)	s0=$(stat -f -c %f "$M")
			$XIO -c "pwrite -q -S 0x5a 0 $big" "$f"
			s1=$(stat -f -c %f "$M")
			$XIO -c "falloc 0 $big" "$M"/g
			s2=$(stat -f -c %f "$M")
			n=$((big / cs))
			# only the fallocate() may have changed $Bitmap meanwhile
			if [ $((s0 - s1)) -lt $n ] || [ $((s1 - s2)) -lt $n ]; then
				fail "$tag: reservation lost: free $s0 -> $s1 after a dirty write of $n clusters -> $s2 after fallocate of $n clusters"
			else echo "PASS: $tag reservation kept ($s0 -> $s1 -> $s2)"; fi ;;
		srm)	echo base > "$f"
			$XIO -c "pwrite -q -S 0x5a 0 $big" "$f":s && rm "$f":s ;;
		sunlink) echo base > "$f"
			$XIO -c "pwrite -q -S 0x5a 0 $big" "$f":s && rm "$f" ;;
		efault)	$XIO -c "truncate $big" -c fsync "$f"
			python3 - "$f" $big <<'PY' || fail "$tag: write from a bad buffer did not fail"
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
libc.pwrite.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_long]
fd = os.open(sys.argv[1], os.O_WRONLY)
r = libc.pwrite(fd, 4096, int(sys.argv[2]) // 2, 0)	# unmapped address
print("pwrite from a bad buffer:", r, os.strerror(ctypes.get_errno()))
sys.exit(0 if r < 0 else 1)
PY
			;;
		esac
		check_leak "$tag"
		umount "$M"
		run_ntfsck $IMG "$case-c$cs"
	done
done
rm -f $IMG
dmesg_check
echo "### done"
