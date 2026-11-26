# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): writeback passes started by
# sync_file_range must not write a folio through a mapping cached before a
# collapse/insert range, punch hole or truncate (see stale_wb_race.py). One
# fresh volume per cluster size of $CLUSTERS, RACE_SECONDS (default 60) each,
# RACE_THREADS (default 2) writeback threads (0 = control), then ntfsck -n
# and a dmesg check.
. "$HARNESS/guest_lib.sh"
mountpoint -q /mnt || mount -t tmpfs -o size=1g tmpfs /mnt
IMG=/mnt/wb-race.img
for cs in $CLUSTERS; do
	tag="wb race c$cs"
	mark "$tag"
	rm -f $IMG; truncate -s 256M $IMG
	mkntfs -F -Q -q -c "$cs" $IMG >/dev/null 2>&1 || { fail "$tag mkntfs"; continue; }
	mount -i -t ntfs -o loop $IMG "$M" || { fail "$tag mount"; continue; }
	if python3 "$HARNESS"/stale_wb_race.py "$M"/f "$cs" "${RACE_SECONDS:-60}" "${RACE_THREADS:-2}"; then
		echo "PASS: $tag"
	else
		fail "$tag: stale data"
	fi
	umount "$M"
	run_ntfsck $IMG "wb-race-c$cs"
done
rm -f $IMG
dmesg_check
echo "### done"
