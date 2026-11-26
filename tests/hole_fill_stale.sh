# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): direct I/O writes and write
# faults into holes must not let concurrent readers see the old contents of
# the clusters they allocate, and neither must writeback of buffered writes
# (see hole_fill_stale.py).  For each of $CLUSTERS and each mode in
# $HOLE_MODES (default "dio buffered mkwrite"): a fresh 64 MiB volume,
# RACE_SECONDS (default 30) of passes, a remount and a check of the file on
# disk, ntfsck -n; a dmesg check at the end.
. "$HARNESS/guest_lib.sh"
mountpoint -q /mnt || mount -t tmpfs -o size=1g tmpfs /mnt
mkdir -p /dev/shm	# multiprocessing needs it
mountpoint -q /dev/shm || mount -t tmpfs tmpfs /dev/shm
IMG=/mnt/hole-fill.img
for mode in ${HOLE_MODES:-dio buffered mkwrite}; do
	for cs in $CLUSTERS; do
		tag="hole fill $mode c$cs"
		mark "$tag"
		rm -f $IMG; truncate -s 64M $IMG
		mkntfs -F -Q -q -c "$cs" $IMG >/dev/null 2>&1 || { fail "$tag mkntfs"; continue; }
		mount -i -t ntfs -o loop $IMG "$M" || { fail "$tag mount"; continue; }
		python3 "$HARNESS"/hole_fill_stale.py "$M" "$cs" "${RACE_SECONDS:-30}" "$mode" "${RACE_READERS:-3}"
		rc=$?
		umount "$M"
		mount -i -t ntfs -o loop $IMG "$M" || { fail "$tag remount"; continue; }
		python3 "$HARNESS"/hole_fill_stale.py "$M" "$cs" 0 "$mode"
		rc2=$?
		umount "$M"
		if [ $rc = 0 ] && [ $rc2 = 0 ]; then
			echo "PASS: $tag"
		else
			fail "$tag: stale data (race rc=$rc, on disk rc=$rc2)"
		fi
		run_ntfsck $IMG "hole-fill-$mode-c$cs"
	done
done
rm -f $IMG
dmesg_check
echo "### done"
