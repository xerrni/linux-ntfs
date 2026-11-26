# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): a buffered write into a hole
# whose writer gets SIGKILL while the copy from user space is blocked
# (userfaultfd on the source buffer) must leave the rest of the cluster it
# stopped in reading as zeroes, and must not mark the volume as having
# errors (that forces VOLUME_IS_DIRTY at unmount). For each of $CLUSTERS:
# killed_short_write (C; built by make -C tests, or by hand with
# "cc -O2 -o killed_short_write killed_short_write.c"), then ntfsck -n and
# the "Failed to zero ... after a short write" error after unmount.
. "$HARNESS/guest_lib.sh"
mountpoint -q /mnt || mount -t tmpfs -o size=1g tmpfs /mnt
IMG=/mnt/killed.img
BIN=$HARNESS/killed_short_write
[ -x "$BIN" ] || { fail "build $BIN on the host first"; exit 0; }
for cs in $CLUSTERS; do
	tag="killed short write c$cs"
	mark "$tag"
	rm -f $IMG; truncate -s 64M $IMG
	mkntfs -F -Q -q -c "$cs" $IMG >/dev/null 2>&1 || { fail "$tag mkntfs"; continue; }
	mount -i -t ntfs -o loop $IMG "$M" || { fail "$tag mount"; continue; }
	if "$BIN" "$M"/f "$cs"; then echo "PASS: $tag data"; else fail "$tag data"; fi
	umount "$M"
	if dmesg | grep -q "after a short write"; then
		fail "$tag: volume marked with errors"
		dmesg -c | grep "after a short write" | head -2
	else
		echo "PASS: $tag no volume error"
	fi
	run_ntfsck $IMG "killed-c$cs"
done
dmesg_check
echo "### done"
