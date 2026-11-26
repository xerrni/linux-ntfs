# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): st_blocks of a file with
# delayed allocation must match what it is after writeback and a remount.
#
# getattr reports i_blocks plus the delalloc clusters (i_dealloc_clusters).
# When writeback allocates a delalloc run with update_mp set (named streams,
# system files, or a volume with 5 % or less free space),
# ntfs_attr_map_cluster() rewrites the mapping pairs, which recounts
# i_dealloc_clusters, and ntfs_write_da_iomap_begin_non_resident() then
# subtracted the allocated clusters a second time.  A failed allocation set
# i_dealloc_clusters to 0 although the delalloc runs stay.
# For each of $CLUSTERS and each case: write, stat, fsync, stat, remount,
# stat; the st_blocks after fsync must equal the one after the remount, and
# the one before fsync must not be lower.
#   plain   1 MiB into a new file (update_mp off: the control)
#   stream  1 MiB into a named stream (update_mp on)
#   full    1 MiB into a new file on a volume with less than 5 % free
#   hole    256 KiB into a hole of a sparse file on that full volume
#   split-stream, split-full: 1 MiB at 0 and at 2 MiB into a named stream or
#           a file on the full volume; sync_file_range() of the first MiB
#           only, which allocates one of the two delalloc runs: st_blocks
#           must not change
# The stream case also checks st_blocks of the file that holds the stream.
. "$HARNESS/guest_lib.sh"
mountpoint -q /mnt || mount -t tmpfs -o size=1g tmpfs /mnt
IMG=/mnt/stblocks.img
blocks() { stat -c %b "$1"; }
check() {	# check TAG PATH BEFORE_FSYNC AFTER_FSYNC
	local tag=$1 p=$2 b1=$3 b2=$4 b3
	umount "$M"; mount -i -t ntfs -o loop,streams_interface=windows $IMG "$M"
	b3=$(blocks "$p")
	echo "$tag: st_blocks before fsync $b1, after fsync $b2, after remount $b3"
	if [ "$b2" != "$b3" ]; then
		fail "$tag: st_blocks $b2 after fsync, $b3 after remount"
	elif [ "$b1" -lt "$b3" ]; then
		fail "$tag: st_blocks $b1 before fsync, $b3 after remount"
	else
		echo "PASS: $tag"
	fi
}
split() {	# split TAG PATH: two delalloc runs, writeback of the first only
	local tag=$1 p=$2 b1 b2 b3
	mark "$tag"
	touch "${p%%:*}"
	xfs_io -f -c "pwrite -q 0 1m" -c "pwrite -q 2m 1m" "$p"
	b1=$(blocks "$p")
	python3 -c "import ctypes, os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
libc = ctypes.CDLL(None, use_errno=True)
# SYNC_FILE_RANGE_WAIT_BEFORE | WRITE | WAIT_AFTER of the first MiB
sys.exit(libc.sync_file_range(fd, ctypes.c_longlong(0), ctypes.c_longlong(1 << 20), 7))" "$p" ||
		fail "$tag sync_file_range"
	b2=$(blocks "$p")
	xfs_io -c fsync "$p"
	b3=$(blocks "$p")
	umount "$M"; mount -i -t ntfs -o loop,streams_interface=windows $IMG "$M"
	b4=$(blocks "$p")
	echo "$tag: st_blocks $b1 written, $b2 after writeback of the first run, $b3 after fsync, $b4 after remount"
	if [ "$b2" != "$b4" ] || [ "$b3" != "$b4" ]; then
		fail "$tag: st_blocks $b2 after writeback of the first run, $b3 after fsync, $b4 after remount"
	else
		echo "PASS: $tag"
	fi
}
for cs in $CLUSTERS; do
	rm -f $IMG; truncate -s 256M $IMG
	mkntfs -F -Q -q -c "$cs" $IMG >/dev/null 2>&1 || { fail "mkntfs c$cs"; continue; }
	mount -i -t ntfs -o loop,streams_interface=windows $IMG "$M" || { fail "mount c$cs"; continue; }

	tag="plain c$cs"; mark "$tag"
	xfs_io -f -c "pwrite -q 0 1m" "$M"/plain
	b1=$(blocks "$M"/plain); xfs_io -c fsync "$M"/plain; b2=$(blocks "$M"/plain)
	check "$tag" "$M"/plain "$b1" "$b2"

	tag="stream c$cs"; mark "$tag"
	touch "$M"/s
	xfs_io -f -c "pwrite -q 0 1m" "$M"/s:data
	b1=$(blocks "$M"/s:data); xfs_io -c fsync "$M"/s:data; b2=$(blocks "$M"/s:data)
	bb=$(blocks "$M"/s)
	check "$tag" "$M"/s:data "$b1" "$b2"
	bb2=$(blocks "$M"/s)
	echo "$tag: st_blocks of the file itself $bb after the stream fsync, $bb2 after remount"
	if [ "$bb" = "$bb2" ]; then
		echo "PASS: $tag base file"
	else
		fail "$tag: base file st_blocks $bb, $bb2 after remount"
	fi

	split "split-stream c$cs" "$M"/s2:data

	# leave about 3 % of the volume free: update_mp is forced below 5 %
	sync
	total=$(stat -f -c %b "$M") free=$(stat -f -c %f "$M")
	xfs_io -f -c "falloc 0 $(( (free - total * 3 / 100) * cs ))" "$M"/fill
	sync
	echo "free $(stat -f -c %f "$M") of $total clusters"

	tag="full c$cs"; mark "$tag"
	xfs_io -f -c "pwrite -q 0 1m" "$M"/full
	b1=$(blocks "$M"/full); xfs_io -c fsync "$M"/full; b2=$(blocks "$M"/full)
	check "$tag" "$M"/full "$b1" "$b2"

	split "split-full c$cs" "$M"/split

	tag="hole c$cs"; mark "$tag"
	xfs_io -f -c "truncate 4m" -c fsync "$M"/hole
	xfs_io -c "pwrite -q 1m 256k" "$M"/hole
	b1=$(blocks "$M"/hole); xfs_io -c fsync "$M"/hole; b2=$(blocks "$M"/hole)
	check "$tag" "$M"/hole "$b1" "$b2"
	umount "$M"
	run_ntfsck $IMG "stblocks-c$cs"
done
rm -f $IMG
dmesg_check
echo "### done"
