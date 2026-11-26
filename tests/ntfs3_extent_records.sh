# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): files whose $DATA attribute is
# split over several MFT records (attribute list + extents), written by
# ntfs-3g, by ntfs3 and by the kernel ntfs driver, must be readable by all
# three drivers and pass ntfsck. Covers:
#  T1 compressed file with extents written by ntfs-3g  (extents carry
#     ATTR_IS_COMPRESSED and compression_unit 4)
#  T2 compressed file with extents written by ntfs3
#  T3 compressed file with extents written by the kernel ntfs driver (the
#     driver cannot create compressed files yet: EOPNOTSUPP is reported as SKIP)
#  T4 sparse file with extents reaching past the volume size, written by
#     ntfs-3g (dense with extents first, then extended with a hole)
#  T5 sparse file with extents, written by the kernel ntfs driver, ending
#     past the end of the volume
# Appending to a compressed file with the kernel ntfs driver is covered by
# ntfs_compressed_stages.sh (it currently damages 512-byte-cluster volumes).
# The raw attribute headers of every record of each file are printed
# (dump_attr_headers.py) so the extent flags / compression unit are visible.
# EXT_CLUSTER (default 512) selects the cluster size of the test volume.
. "$HARNESS/guest_lib.sh"
cs=${EXT_CLUSTER:-512}
img=$W/ext-$cs.img; rm -f "$img" "$W"/exp-ext.json; truncate -s 64M "$img"
mkntfs -F -Q -q -c "$cs" "$img" >/dev/null 2>&1 || { fail "mkntfs"; exit; }
records() {	# records IMG PATH: MFT numbers holding attributes of PATH
	"$NTFSINFO" -F "$2" "$1" | sed -n 's/.*from mft record \([0-9]*\) .*/\1/p' | sort -un
}
text() {	# text PATH SIZE SEED [append]: compressible data, recorded in exp-ext.json
	python3 - "$1" "$2" "$3" "$W"/exp-ext.json "${4:-}" <<'PY'
import hashlib, json, os, random, sys
p, size, seed, ef, mode = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
r = random.Random(seed)
words = [bytes(r.choice(b"abcdefghij ") for _ in range(r.randint(2, 9))) for _ in range(300)]
buf = bytearray()
while len(buf) < size:
    buf += r.choice(words) + b" "
    if r.random() < 0.0005:
        buf += r.randbytes(r.randint(64, 4096))	# incompressible islands
data = bytes(buf[:size])
with open(p, "ab" if mode else "wb") as f:
    f.write(data)
if mode:
    data = open(p, "rb").read()
    size = len(data)
e = json.load(open(ef)) if os.path.exists(ef) else {}
e[p] = {"sha256": hashlib.sha256(data).hexdigest(), "size": size}
json.dump(e, open(ef, "w"), indent=1)
print("wrote", p, size)
PY
}
mount_drv ntfs-3g "$img" rw || { fail "ntfs-3g mount"; exit; }
chunk=$((2 * cs)); [ $chunk -lt 1024 ] && chunk=1024
python3 "$HARNESS"/make_fragmented.py "$M" $chunk
mkdir "$M"/comp && setfattr -h -v 0x00000810 -n system.ntfs_attrib_be "$M"/comp
getfattr -h -e hex -n system.ntfs_attrib_be "$M"/comp
text "$M"/comp/t1-ntfs3g.txt 3000000 1
# T4: dense file with extents, then a hole far past the end of the volume
python3 -c "import os,sys;open(sys.argv[1],'wb').write(os.urandom(2<<20))" "$M"/t4-ntfs3g.bin
python3 - "$M"/t4-ntfs3g.bin "$W"/exp-ext.json <<'PY'
import hashlib, json, os, sys
p, ef = sys.argv[1], sys.argv[2]
with open(p, "r+b") as f:
    f.seek(200 << 20); f.write(b"tail after a 198 MiB hole")
data = open(p, "rb").read()
e = json.load(open(ef)) if os.path.exists(ef) else {}
e[p] = {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
json.dump(e, open(ef, "w"), indent=1)
PY
umount "$M"
mount_drv ntfs3 "$img" rw || fail "ntfs3 mount rw"
text "$M"/comp/t2-ntfs3.txt 3000000 2
umount "$M"
mount_drv ntfs "$img" rw || fail "ntfs mount rw"
text "$M"/comp/t3-ntfs.txt 3000000 3 2>/dev/null || echo "SKIP: T3, the ntfs driver does not create compressed files"
python3 "$HARNESS"/sparse_ops.py "$M"/t5-ntfs.bin "$cs" 5 "$W"/exp-ext.json --new || fail "T5 ops"
python3 - "$M"/t5-ntfs.bin "$W"/exp-ext.json <<'PY'
import hashlib, json, sys
p, ef = sys.argv[1], sys.argv[2]
with open(p, "r+b") as f:	# end the file far past the end of the volume
    f.seek(300 << 20); f.write(b"tail after a hole")
data = open(p, "rb").read()
e = json.load(open(ef))
e[p] = {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
json.dump(e, open(ef, "w"), indent=1)
PY
umount "$M"
for f in /comp/t1-ntfs3g.txt /comp/t2-ntfs3.txt /comp/t3-ntfs.txt /t4-ntfs3g.bin /t5-ntfs.bin; do
	echo "--- $f"
	read -ra recs <<< "$(records "$img" "$f" | tr '\n' ' ')"
	python3 "$HARNESS"/dump_attr_headers.py "$img" "${recs[@]}" | grep -E "^record|\\\$DATA"
done
run_ntfsck "$img" ext-"$cs"
for drv in ntfs ntfs3 ntfs-3g; do
	mount_drv $drv "$img" ro || { fail "mount $drv"; continue; }
	mark "verify with $drv"
	python3 - "$W"/exp-ext.json $drv <<'PY'
import hashlib, json, sys
bad = 0
for p, m in json.load(open(sys.argv[1])).items():
    try:
        ok = hashlib.sha256(open(p, "rb").read()).hexdigest() == m["sha256"]
        msg = "ok" if ok else "DIFF"
    except OSError as e:
        ok, msg = False, f"ERR {e.strerror}"
    print(("PASS" if ok else "FAIL") + f": {sys.argv[2]} reads {p.rsplit('/', 1)[1]}: {msg}")
PY
	umount "$M"
done
dmesg | grep -E "ntfs3\(|ntfs:" | grep -v "volume version\|put_super" | tail -20
dmesg_check
echo "### done"
