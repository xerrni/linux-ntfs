# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): an O_DIRECT write into
# clusters reserved with FALLOC_FL_KEEP_SIZE that fails part way (its source
# turns unmapped after 4 MiB of 6 MiB) must not leave old disk contents
# readable.  Asynchronous (io_submit) and synchronous (pwritev) writes, three
# files each, on a volume whose free space held 0xee.  Checked right after
# the write (aio_dio_partial, C, built by make -C tests) and after a
# remount; ntfsck -n at the end.  A non-blocking direct write that would
# move the initialized size (pwritev2() with RWF_NOWAIT, 4 MiB, all of it
# mapped) must fail with EAGAIN and leave the size alone, into a reserved
# file and into a new empty (resident) one.  Fails on ntfs-next for the asynchronous
# write: iomap returns -EIOCBQUEUED while bios are in flight, so the size
# rollback of a failed write does not run.
. "$HARNESS/guest_lib.sh"
mountpoint -q /mnt || mount -t tmpfs -o size=1g tmpfs /mnt
IMG=/mnt/aio-dio.img
BIN=$HARNESS/aio_dio_partial
[ -x "$BIN" ] || { fail "build $BIN on the host first"; exit 0; }
old() {	# old FILE: number of 0xee bytes in FILE
	python3 -c "import sys; print(open(sys.argv[1], 'rb').read().count(b'\xee'))" "$1"
}
for cs in $CLUSTERS; do
	rm -f $IMG; truncate -s 128M $IMG
	mkntfs -F -Q -q -c "$cs" $IMG >/dev/null 2>&1 || { fail "mkntfs c$cs"; continue; }
	mount -i -t ntfs -o loop $IMG "$M" || { fail "mount c$cs"; continue; }
	python3 - "$M"/old <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT)
b = b'\xee' * (1 << 20)
try:
    while True:
        os.write(fd, b)
except OSError:
    pass
os.fsync(fd)
PY
	sync; rm "$M"/old; sync
	for mode in aio sync; do
		for n in 1 2 3; do
			tag="partial $mode dio c$cs #$n"; mark "$tag"
			f=$M/$mode-$n
			xfs_io -f -c "falloc -k 0 $((6 << 20))" "$f"
			if "$BIN" "$f" $((4 << 20)) $((6 << 20)) $mode; then
				echo "PASS: $tag"
			else
				fail "$tag: old data readable"
			fi
		done
	done
	for kind in reserved empty; do
		tag="nowait dio into a $kind file c$cs"; mark "$tag"
		f=$M/nowait
		rm -f "$f"; touch "$f"
		# an empty file is resident until the write makes it non-resident
		[ $kind = reserved ] && xfs_io -c "falloc -k 0 $((6 << 20))" "$f"
		if "$BIN" "$f" $((4 << 20)) $((6 << 20)) nowait; then
			echo "PASS: $tag returns EAGAIN"
		else
			fail "$tag: no EAGAIN or the size moved"
		fi
		rm -f "$f"
	done
	umount "$M"
	mount -i -t ntfs -o loop $IMG "$M" || { fail "remount c$cs"; continue; }
	for f in "$M"/aio-* "$M"/sync-*; do
		n=$(old "$f")
		if [ "$n" = 0 ]; then
			echo "PASS: no old data in $(basename "$f") after remount c$cs"
		else
			fail "$(basename "$f") c$cs: $n bytes of old data after remount (size $(stat -c %s "$f"))"
		fi
	done
	umount "$M"
	run_ntfsck $IMG "aio-dio-c$cs"
done
dmesg_check
echo "### done"
