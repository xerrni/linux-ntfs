# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): buffered writes into holes
# racing with writeback started by FIEMAP_FLAG_SYNC from other threads must
# not expose the old contents of reallocated clusters (see
# delalloc_zero_race.py).  One fresh volume per cluster size of $CLUSTERS,
# RACE_SECONDS (default 30) of rounds each, then ntfsck -n and a dmesg check.
# RACE_THREADS (default 3) FIEMAP threads; 0 = control run without them.
. "$HARNESS/guest_lib.sh"
mountpoint -q /mnt || mount -t tmpfs -o size=1g tmpfs /mnt
IMG=/mnt/zero-race.img
for cs in $CLUSTERS; do
	tag="zero race c$cs"
	mark "$tag"
	rm -f $IMG; truncate -s 128M $IMG
	mkntfs -F -Q -q -c "$cs" $IMG >/dev/null 2>&1 || { fail "$tag mkntfs"; continue; }
	mount -i -t ntfs -o loop $IMG "$M" || { fail "$tag mount"; continue; }
	if python3 "$HARNESS"/delalloc_zero_race.py "$M"/f "$cs" "${RACE_SECONDS:-30}" "${RACE_THREADS:-3}"; then
		echo "PASS: $tag"
	else
		fail "$tag: stale data"
	fi
	umount "$M"
	run_ntfsck $IMG "zero-race-c$cs"
done
rm -f $IMG
dmesg | grep -c "ntfs-instr" | sed 's/^/instrumentation lines: /'
dmesg | grep "ntfs-instr" | head -5
dmesg_check
echo "### done"
