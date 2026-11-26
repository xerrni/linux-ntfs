# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): write a compressed file with
# the kernel ntfs driver on a volume whose free space is split into small
# holes, then check that no other file changed.
#
# Every compression block needs up to 15 clusters; the holes hold
# FRAG_HOLE_CLUSTERS (default 2), so a compression block cannot be stored in
# one run. Steps, all with the kernel driver unless CREATOR=ntfs-3g:
#  1 mkntfs (FRAG_CLUSTER, default 512 bytes), fill the volume with files of
#    identical content, delete every other one
#  2 create an empty file and mark it compressed (system.ntfs_attrib_be
#    0x800), or with CREATOR=ntfs-3g let ntfs-3g create it in a compressed
#    directory with the first 20 KiB of the text
#  3 write (append) the rest of FRAG_WRITE_KB (default 256) KiB of
#    compressible text with the kernel driver (no O_TRUNC: the driver does
#    not support changing the size of a compressed file)
#  4 remount: the file reads back, every remaining filler file still has
#    the filler content, ntfsck -n is clean, ntfs-3g and ntfs3 read it too
. "$HARNESS/guest_lib.sh"
gen_text() {	# gen_text MNT EXPECT KB HEAD_KB: write KB KiB of text; the first
		# HEAD_KB KiB only if HEAD_KB > 0 (creating the file), else the rest
	python3 - "$@" <<'PY'
import hashlib, json, os, random, sys
mnt, ef, kb, head = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
fill = sorted(os.listdir(os.path.join(mnt, "frag")))
blob = hashlib.sha256(open(os.path.join(mnt, "frag", fill[0]), "rb").read()).hexdigest()
r = random.Random(4)
words = [bytes(r.choice(b"abcdefghij ") for _ in range(r.randint(2, 9))) for _ in range(300)]
buf = bytearray()
while len(buf) < kb << 10:
    buf += r.choice(words) + b" "
data = bytes(buf[:kb << 10])
p = os.path.join(mnt, "comp", "c.txt")
if head > 0:
    with open(p, "wb") as f:
        f.write(data[:head << 10])
    print(f"created {p} with {head} KiB")
    sys.exit(0)
start = os.path.getsize(p)
with open(p, "r+b") as f:
    f.seek(start)
    f.write(data[start:])
    f.flush()
    os.fsync(f.fileno())
json.dump({"blob": blob, "files": len(fill), "c": hashlib.sha256(data).hexdigest()}, open(ef, "w"))
print(f"wrote {len(data) - start} bytes at {start}; {len(fill)} filler files")
PY
}
cs=${FRAG_CLUSTER:-512}
hole=$(( ${FRAG_HOLE_CLUSTERS:-2} * cs )); [ $hole -lt 1024 ] && hole=1024
img=$W/frag-$cs.img; rm -f "$img"; truncate -s "${FRAG_VOLUME_MB:-32}"M "$img"
mkntfs -F -Q -q -c "$cs" "$img" >/dev/null 2>&1 || { fail "mkntfs"; exit; }
if [ "${CREATOR:-ntfs}" = ntfs-3g ]; then
	mount_drv ntfs-3g "$img" rw || { fail "ntfs-3g mount"; exit; }
	python3 "$HARNESS"/make_fragmented.py "$M" $hole
	mkdir "$M"/comp && setfattr -h -v 0x00000810 -n system.ntfs_attrib_be "$M"/comp
	gen_text "$M" "$W"/frag-expect.json "${FRAG_WRITE_KB:-256}" 20
	umount "$M"
	mount_drv ntfs "$img" rw || { fail "ntfs mount"; exit; }
else
	mount_drv ntfs "$img" rw || { fail "ntfs mount"; exit; }
	python3 "$HARNESS"/make_fragmented.py "$M" $hole
	mkdir "$M"/comp
	: > "$M"/comp/c.txt
	setfattr -h -v 0x00000800 -n system.ntfs_attrib_be "$M"/comp/c.txt || fail "set compressed"
fi
getfattr -h -e hex -n system.ntfs_attrib_be "$M"/comp/c.txt
gen_text "$M" "$W"/frag-expect.json "${FRAG_WRITE_KB:-256}" 0 || fail "kernel write"
umount "$M"
python3 "$HARNESS"/dump_attr_headers.py "$img" "$(mft_no "$img" /comp/c.txt)" | grep -E "DATA"
run_ntfsck "$img" frag-"$cs"
for drv in ntfs ntfs-3g ntfs3; do
	mount_drv $drv "$img" ro || { fail "mount $drv"; continue; }
	python3 - "$M" "$W"/frag-expect.json $drv <<'PY'
import hashlib, json, os, sys
mnt, e, drv = sys.argv[1], json.load(open(sys.argv[2])), sys.argv[3]
bad = []
for n in sorted(os.listdir(os.path.join(mnt, "frag"))):
    try:
        if hashlib.sha256(open(os.path.join(mnt, "frag", n), "rb").read()).hexdigest() != e["blob"]:
            bad.append(n)
    except OSError as x:
        bad.append(f"{n} ({x.strerror})")
print(("FAIL" if bad else "PASS") + f": {drv}: filler files intact ({len(bad)} of {e['files']} changed) {bad[:5]}")
try:
    ok = hashlib.sha256(open(os.path.join(mnt, "comp", "c.txt"), "rb").read()).hexdigest() == e["c"]
    print(("PASS" if ok else "FAIL") + f": {drv}: compressed file " + ("ok" if ok else "DIFF"))
except OSError as x:
    print(f"FAIL: {drv}: compressed file {x.strerror}")
PY
	umount "$M"
done
dmesg | grep -E "ntfs3\(|ntfs:" | grep -v "volume version\|put_super" | tail -8
dmesg_check
echo "### done"
