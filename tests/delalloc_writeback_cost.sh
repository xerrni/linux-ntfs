# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): time the writeback of a new
# file written through the page cache, so all of it is delalloc, to see what
# allocating a delalloc run in many small pieces costs at writeback.
#
# For each cluster size in WB_CLUSTERS (default "512 4096") on a RAM-backed
# loop file (so the disk costs little): RUNS (default 5) times, create a new
# FILE_MB (default 256) MiB file with 1 MiB buffered writes, time fsync, and
# count the file's extents with filefrag.  Prints one line per run; compare
# the times of two kernels.  Writes nothing else.
. "$HARNESS/guest_lib.sh"
mountpoint -q /mnt || mount -t tmpfs -o size=2g tmpfs /mnt
FILE_MB=${FILE_MB:-256}
RUNS=${RUNS:-5}
IMG=/mnt/wbda.img
for cs in ${WB_CLUSTERS:-512 4096}; do
	rm -f $IMG; truncate -s $((FILE_MB * 2 + 128))M $IMG
	mkntfs -F -Q -q -c "$cs" $IMG >/dev/null 2>&1 || { fail "mkntfs c$cs"; continue; }
	mount -i -t ntfs -o loop $IMG "$M" || { fail "mount c$cs"; continue; }
	for run in $(seq "$RUNS"); do
		python3 - "$M/f" "$FILE_MB" <<'PY'
import os, sys, time
path, mb = sys.argv[1], int(sys.argv[2])
buf = b"\x5a" * (1 << 20)
fd = os.open(path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o644)
for i in range(mb):
    os.write(fd, buf)
t = time.monotonic()
os.fsync(fd)
print("fsync %.3f s" % (time.monotonic() - t), end=" ")
os.close(fd)
PY
		echo "c$cs run $run $(filefrag "$M/f" 2>/dev/null | sed 's/.*: //')"
		rm -f "$M/f"; sync
	done
	umount "$M"
	echo "PASS: delalloc writeback cost c$cs measured"
done
rm -f $IMG
dmesg_check
echo "### done"
