# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): a buffered write into a hole
# below initialized_size whose copy from user space stops part way through a
# cluster (the source buffer runs into an unmapped page) must leave the rest of
# that cluster reading as zeroes, also after writeback and drop_caches.
#
# ->iomap_begin() makes the whole cluster delalloc; only the bytes copied get
# dirty, the rest of the cluster is not zeroed in the page cache, writeback
# allocates the cluster and writes only the dirty blocks, and the other blocks
# keep the old contents of the reused clusters (here: the file's own data from
# before a truncate).  For each of $CLUSTERS: fill + fsync + truncate to 0 and
# back up, extend initialized_size with a write at the end, then a write of
# 2.5 clusters at a cluster boundary from a buffer with only COPY bytes
# mapped; then a write into a hole whose source buffer is an mmap() of the
# same file (page faults during the copy); ntfsck -n clean.
. "$HARNESS/guest_lib.sh"
mountpoint -q /mnt || mount -t tmpfs -o size=1g tmpfs /mnt
IMG=/mnt/short-copy.img
for cs in $CLUSTERS; do
	tag="short copy c$cs"
	mark "$tag"
	rm -f $IMG; truncate -s 64M $IMG
	mkntfs -F -Q -q -c "$cs" $IMG >/dev/null 2>&1 || { fail "$tag mkntfs"; continue; }
	mount -i -t ntfs -o loop $IMG "$M" || { fail "$tag mount"; continue; }
	if python3 - "$M"/f "$cs" <<'PY'; then echo "PASS: $tag"; else fail "$tag"; fi
import ctypes, mmap, os, sys
path, cs = sys.argv[1], int(sys.argv[2])
nclu = 32
size = nclu * cs
libc = ctypes.CDLL(None, use_errno=True)
libc.pwrite.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_long]
libc.mprotect.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
bad = []
for copy in (1000, 4096 + 1000, 3 * 4096 + 512):
    os.pwrite(fd, b"\xab" * size, 0)
    os.fsync(fd)
    os.ftruncate(fd, 0)
    os.ftruncate(fd, size)
    os.pwrite(fd, b"\x01", size - 1)            # initialized_size = size
    # buffer: COPY readable bytes, then a PROT_NONE page
    pages = (copy + 4095) // 4096 + 1
    m = mmap.mmap(-1, pages * 4096)
    base = ctypes.addressof(ctypes.c_char.from_buffer(m))
    start = base + (pages - 1) * 4096 - copy
    ctypes.memset(start, 0x5c, copy)
    if libc.mprotect(base + (pages - 1) * 4096, 4096, 0):
        sys.exit("mprotect failed")
    off = 8 * cs
    r = libc.pwrite(fd, start, 2 * cs + cs // 2, off)
    libc.mprotect(base + (pages - 1) * 4096, 4096, 3)
    del start
    print(f"copy {copy}: pwrite of {2 * cs + cs // 2} at {off} returned {r}", flush=True)
    os.fsync(fd)
    with open("/proc/sys/vm/drop_caches", "w") as f:
        f.write("3\n")
    data = os.pread(fd, size, 0)
    exp = bytearray(size)
    exp[size - 1] = 1
    if r > 0:
        exp[off:off + r] = b"\x5c" * r
    if data != bytes(exp):
        i = next(i for i in range(size) if data[i] != exp[i])
        j = i
        while j < size and data[j] != exp[j]:
            j += 1
        bad.append(f"copy {copy}: stale data at {i}..{j}: got {data[i:i + 8].hex()} want {bytes(exp[i:i + 8]).hex()}")
# a write into a hole whose source is a not yet faulted in mmap() of the
# same file: page faults during the copy while ->iomap_begin() takes the
# invalidate lock (lockdep and the hang detector watch this)
os.pwrite(fd, b"\xcd" * (4 * cs), 0)
os.fsync(fd)
with open("/proc/sys/vm/drop_caches", "w") as f:
    f.write("3\n")
src = mmap.mmap(fd, 4 * cs, prot=mmap.PROT_READ)
view = memoryview(src)
r = os.pwrite(fd, view, 16 * cs + 100)        # the kernel faults the source in
view.release()
src.close()
same = os.pread(fd, 4 * cs, 16 * cs + 100) == b"\xcd" * (4 * cs)
print(f"write from an mmap of the same file returned {r}, data {'ok' if same else 'wrong'}")
if r != 4 * cs or not same:
    bad.append("write from an mmap of the same file failed")
os.close(fd)
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
PY
	umount "$M"
	run_ntfsck $IMG "short-copy-c$cs"
done
rm -f $IMG
dmesg_check
echo "### done"
