# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): a buffered write into a hole
# whose delalloc mapping goes stale while its copy is blocked (userfaultfd):
# a byte stored through a shared mapping next to where the write ends is
# written back, which allocates the clusters, and its page is dropped from
# the page cache before the copy resumes. The byte must survive. Fails on
# ntfs-next: the write zeroes the rest of its last block instead of reading
# it back. For each of $CLUSTERS, with the file initialized up to its end
# and without: stale_write_mapping (C, built by make -C tests), then
# ntfsck -n.
. "$HARNESS/guest_lib.sh"
mountpoint -q /mnt || mount -t tmpfs -o size=1g tmpfs /mnt
IMG=/mnt/stalewm.img
BIN=$HARNESS/stale_write_mapping
[ -x "$BIN" ] || { fail "build $BIN on the host first"; exit 0; }
for cs in $CLUSTERS; do
	rm -f $IMG; truncate -s 64M $IMG
	mkntfs -F -Q -q -c "$cs" $IMG >/dev/null 2>&1 || { fail "mkntfs c$cs"; continue; }
	mount -i -t ntfs -o loop $IMG "$M" || { fail "mount c$cs"; continue; }
	unit=$((cs > 4096 ? cs : 4096))
	for init in 0 full; do
		tag="stale write mapping init=$init c$cs"
		mark "$tag"
		f=$M/f-$init
		xfs_io -f -c "truncate $((16 * unit))" "$f"
		[ $init = full ] && xfs_io -c "pwrite -q $((16 * unit - 512)) 512" "$f"
		xfs_io -c fsync "$f"
		if "$BIN" "$f" $((4 * unit)); then echo "PASS: $tag"; else fail "$tag"; fi
	done
	umount "$M"
	run_ntfsck $IMG "stalewm-c$cs"
done
dmesg_check
echo "### done"
