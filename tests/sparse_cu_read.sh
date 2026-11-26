# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): can the kernel ntfs driver READ
# sparse files whose $DATA has compression_unit 4 (what ntfs-3g/libntfs and
# Windows write) on every cluster size?  Works on old kernels too (7.1-7.3
# have no streams_interface: the stream checks then just report ERR).
#  1. every file (and ADS) of the fixture images $FIXTURES/c*.img, read-only
#  2. fresh volumes for each of $CLUSTERS: sparse file + sparse named stream
#     written by ntfs-3g, then read back with the kernel driver
# Look for "Found non-standard compression unit" in the output / dmesg.
. "$HARNESS/guest_lib.sh"
for img in "$FIXTURES"/c*.img; do
	[ -e "$img" ] || { echo "SKIP: no fixture images (set FIXTURES)"; break; }
	fx=${img%.img}
	mark "fixture $(basename "$fx") read-only"
	if mount -i -t ntfs -o ro,loop,streams_interface=windows "$img" "$M" 2>/dev/null; then
		if python3 "$HARNESS"/verify_tree.py "$M" --manifest "$fx".json --ads; then echo "PASS: read $fx"; else fail "read $fx"; fi
		umount "$M"
	elif mount -i -t ntfs -o ro,loop "$img" "$M"; then
		if python3 "$HARNESS"/verify_tree.py "$M" --manifest "$fx".json; then echo "PASS: read $fx"; else fail "read $fx"; fi
		umount "$M"
	else fail "mount $fx"; fi
	dmesg | grep "compression unit" | tail -2
done
for cs in $CLUSTERS; do
	img=$W/read-$cs.img; rm -f "$img" "$W"/exp-read-"$cs".json; truncate -s 512M "$img"
	mkntfs -F -Q -q -c "$cs" "$img" >/dev/null 2>&1 || { fail "mkntfs $cs"; continue; }
	mark "ntfs-3g writes sparse files, cluster $cs"
	ntfs-3g -o streams_interface=windows "$img" "$M" || { fail "ntfs-3g mount $cs"; continue; }
	echo hello > "$M"/host.txt
	python3 "$HARNESS"/sparse_ops.py "$M"/sparse.bin "$cs" 11 "$W"/exp-read-"$cs".json --new --simple
	python3 "$HARNESS"/sparse_ops.py "$M"/host.txt:sp "$cs" 12 "$W"/exp-read-"$cs".json --new --simple
	umount "$M"
	cu "$img" /sparse.bin /host.txt
	mark "kernel ntfs reads them, cluster $cs"
	if mount -i -t ntfs -o ro,loop,streams_interface=windows "$img" "$M" 2>/dev/null ||
	   mount -i -t ntfs -o ro,loop "$img" "$M"; then
		if python3 "$HARNESS"/verify_tree.py / --expect "$W"/exp-read-"$cs".json; then echo "PASS: read cs=$cs"; else fail "read cs=$cs"; fi
		umount "$M"
	else fail "mount cs=$cs"; fi
	dmesg | grep "compression unit" | tail -2
	rm -f "$img"
done
dmesg_check
echo "### done"
