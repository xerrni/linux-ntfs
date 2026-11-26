# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): time the writeback of a fully
# dirty file, contiguous and fragmented, to catch writeback work that grows
# with extents x dirty pages instead of with the dirty pages alone.
#
# For a 4 KiB cluster volume on a RAM-backed loop file (so the disk costs
# little): build FILE_MB MiB once as a contiguous file and once with EXTENTS
# extents (two files written in alternating chunks, then the other removed),
# overwrite the whole file through the page cache and time fsync. Prints
# both times, RUNS times each; the ratio is the result. Writes nothing else.
. "$HARNESS/guest_lib.sh"
mountpoint -q /mnt || mount -t tmpfs -o size=3g tmpfs /mnt
FILE_MB=${FILE_MB:-1024}
EXTENTS=${EXTENTS:-4000}
RUNS=${RUNS:-3}
IMG=/mnt/wbcost.img
rm -f $IMG; truncate -s $((FILE_MB * 2 + 256))M $IMG
mkntfs -F -Q -q -c 4096 $IMG >/dev/null 2>&1 || { fail "mkntfs"; exit 0; }
mount -i -t ntfs -o loop $IMG "$M" || { fail "mount"; exit 0; }
python3 - "$M" "$FILE_MB" "$EXTENTS" "$RUNS" <<'PY'
import os, sys, time
mnt, mb, extents, runs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
size = mb << 20
chunk = (size // extents) // 4096 * 4096
buf = b"\x5a" * (1 << 20)
def fill(fd, length):
    off = 0
    while off < length:
        n = min(len(buf), length - off)
        os.pwrite(fd, buf[:n], off)
        off += n
# contiguous file
c = os.open(f"{mnt}/contig", os.O_RDWR | os.O_CREAT, 0o644)
fill(c, size); os.fsync(c)
# fragmented file: interleave with a filler file, then remove the filler
f = os.open(f"{mnt}/frag", os.O_RDWR | os.O_CREAT, 0o644)
g = os.open(f"{mnt}/filler", os.O_RDWR | os.O_CREAT, 0o644)
for i in range(extents):
    os.pwrite(f, buf[:chunk] if chunk <= len(buf) else b"\x5a" * chunk, i * chunk)
    os.fsync(f)
    os.pwrite(g, b"\x00" * 4096, i * 4096)
    os.fsync(g)
os.close(g); os.unlink(f"{mnt}/filler")
os.ftruncate(f, extents * chunk)
os.fsync(f)
for name, fd, length in (("contig", c, size), ("frag", f, extents * chunk)):
    for r in range(runs):
        fill(fd, length)
        t = time.monotonic()
        os.fsync(fd)
        print(f"{name} run {r}: fsync of {length >> 20} MiB took {time.monotonic() - t:.3f} s", flush=True)
PY
filefrag "$M"/frag 2>/dev/null | tail -1
umount "$M"
dmesg_check
echo "### done"
