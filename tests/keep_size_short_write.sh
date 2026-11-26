# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): a short buffered write past
# the end of a file must not free clusters preallocated there with
# fallocate(FALLOC_FL_KEEP_SIZE).
#
# ntfs_file_write_iter() raises the sizes to pos + count before copying and
# rolls them back when the copy stops early.  The rollback truncates the
# attribute to the new size; if that also cuts the allocation, the space the
# application reserved with KEEP_SIZE is gone after a write that returned a
# short count.  For each of $CLUSTERS: a file of 16 clusters, KEEP_SIZE
# preallocation of 32 more, then a write of 8 clusters at the old end from a
# buffer with only 2.5 clusters mapped.  Checks: the short count, the size,
# the data, and that st_blocks still covers the preallocation, before and
# after a remount; ntfsck -n clean.
. "$HARNESS/guest_lib.sh"
mountpoint -q /mnt || mount -t tmpfs -o size=1g tmpfs /mnt
IMG=/mnt/keep-size.img
for cs in $CLUSTERS; do
	tag="keep-size short write c$cs"
	mark "$tag"
	rm -f $IMG; truncate -s 64M $IMG
	mkntfs -F -Q -q -c "$cs" $IMG >/dev/null 2>&1 || { fail "$tag mkntfs"; continue; }
	mount -i -t ntfs -o loop $IMG "$M" || { fail "$tag mount"; continue; }
	python3 - "$M"/f "$cs" before <<'PY' || fail "$tag"
import ctypes, mmap, os, sys
path, cs, phase = sys.argv[1], int(sys.argv[2]), sys.argv[3]
old = 16 * cs
prealloc_end = 48 * cs
libc = ctypes.CDLL(None, use_errno=True)
libc.pwrite.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_long]
libc.mprotect.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
libc.fallocate.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_long, ctypes.c_long]
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
os.pwrite(fd, b"\x11" * old, 0)
os.fsync(fd)
if libc.fallocate(fd, 1, old, prealloc_end - old):      # FALLOC_FL_KEEP_SIZE
    sys.exit(f"fallocate KEEP_SIZE: errno {ctypes.get_errno()}")
os.fsync(fd)
st = os.fstat(fd)
print(f"after fallocate: size {st.st_size} blocks {st.st_blocks * 512}", flush=True)
if st.st_size != old or st.st_blocks * 512 < prealloc_end:
    sys.exit("fallocate did not preallocate")
copy = 2 * cs + cs // 2
pages = (copy + 4095) // 4096 + 1
m = mmap.mmap(-1, pages * 4096)
base = ctypes.addressof(ctypes.c_char.from_buffer(m))
start = base + (pages - 1) * 4096 - copy
ctypes.memset(start, 0x5c, copy)
if libc.mprotect(base + (pages - 1) * 4096, 4096, 0):
    sys.exit("mprotect failed")
r = libc.pwrite(fd, start, 8 * cs, old)
libc.mprotect(base + (pages - 1) * 4096, 4096, 3)
os.fsync(fd)
st = os.fstat(fd)
print(f"pwrite of {8 * cs} at {old} returned {r}; size {st.st_size} blocks {st.st_blocks * 512}", flush=True)
bad = []
if r <= 0 or r >= 8 * cs:
    bad.append(f"expected a short write, got {r}")
if st.st_size != old + max(r, 0):
    bad.append(f"size {st.st_size}, expected {old + max(r, 0)}")
if st.st_blocks * 512 < prealloc_end:
    bad.append(f"preallocation lost: {st.st_blocks * 512} bytes allocated, {prealloc_end} expected")
with open("/proc/sys/vm/drop_caches", "w") as f:
    f.write("3\n")
data = os.pread(fd, old + 8 * cs, 0)
if data != b"\x11" * old + b"\x5c" * max(r, 0):
    bad.append("data differs")
open(path + ".r", "w").write(str(r))
if bad:
    sys.exit("; ".join(bad))
print("ok", flush=True)
PY
	r=$(cat "$M"/f.r 2>/dev/null); rm -f "$M"/f.r
	umount "$M" || { fail "$tag umount"; continue; }
	mount -i -t ntfs -o loop $IMG "$M" || { fail "$tag remount"; continue; }
	if python3 - "$M"/f "$cs" "$r" <<'PY'; then echo "PASS: $tag"; else fail "$tag"; fi
import os, sys
path, cs, r = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
st = os.stat(path)
print(f"after remount: size {st.st_size} blocks {st.st_blocks * 512}", flush=True)
bad = []
if st.st_size != 16 * cs + r:
    bad.append(f"size {st.st_size} after remount")
if st.st_blocks * 512 < 48 * cs:
    bad.append(f"preallocation lost after remount: {st.st_blocks * 512}")
if bad:
    sys.exit("; ".join(bad))
PY
	umount "$M"
	run_ntfsck $IMG "c$cs"
done
dmesg_check
echo "### done"
