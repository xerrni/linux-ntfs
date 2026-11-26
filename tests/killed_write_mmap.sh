# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): a file with old data past
# its initialized size (set with set_init_size.py, as Windows leaves files
# after SetFileValidData()) gets a buffered write whose writer is killed
# while its copy is blocked (userfaultfd), after the test mapped the file
# (which initializes it whole) and wrote a page through the mapping. The
# mapped page must keep its data and the old data must not show: the part
# of the write that was not copied must read as zeroes. Fails on ntfs-next
# (old data) and with "ntfs: trim the sizes after a short write" v8 (the
# mapped page is lost when zeroing stops on the pending SIGKILL). For each
# of $CLUSTERS: killed_write_mmap (C, built by make -C tests), then
# ntfsck -n.
. "$HARNESS/guest_lib.sh"
mountpoint -q /mnt || mount -t tmpfs -o size=1g tmpfs /mnt
IMG=/mnt/killedm.img
BIN=$HARNESS/killed_write_mmap
[ -x "$BIN" ] || { fail "build $BIN on the host first"; exit 0; }
for cs in $CLUSTERS; do
	tag="killed write mmap c$cs"
	mark "$tag"
	rm -f $IMG; truncate -s 64M $IMG
	mkntfs -F -Q -q -c "$cs" $IMG >/dev/null 2>&1 || { fail "$tag mkntfs"; continue; }
	mount -i -t ntfs -o loop $IMG "$M" || { fail "$tag mount"; continue; }
	size=$((64 * cs > 2097152 ? 64 * cs : 2097152))
	python3 -c "import sys; sys.stdout.buffer.write(b'\xab' * $size)" > "$M"/f
	umount "$M"
	python3 "$HARNESS/set_init_size.py" $IMG f 0 || { fail "$tag set_init_size"; continue; }
	mount -i -t ntfs -o loop $IMG "$M" || { fail "$tag mount 2"; continue; }
	if "$BIN" "$M"/f "$cs"; then echo "PASS: $tag data"; else fail "$tag data"; fi
	umount "$M"
	if dmesg | grep -q "after a short write"; then
		fail "$tag: volume marked with errors"
		dmesg -c | grep "after a short write" | head -2
	else
		echo "PASS: $tag no volume error"
	fi
	run_ntfsck $IMG "killedm-c$cs"
done
dmesg_check
echo "### done"
