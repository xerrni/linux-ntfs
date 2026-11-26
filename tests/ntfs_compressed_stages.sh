# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): stage-by-stage check of a
# fragmented volume with compressed files, written in turn by ntfs-3g, ntfs3
# and the kernel ntfs driver. ntfsck -n runs after every stage and a copy of
# the image is kept as $W/stage-N.img, so the stage that damages the volume
# shows up directly. Stages:
#  1 ntfs-3g: fragment free space, compressed dir, t1 (3 MB) and t6 (300 kB)
#  2 ntfs3: writes t2 (3 MB) into the compressed dir
#  3 kernel ntfs: tries to create t3 in the compressed dir
#  4 kernel ntfs: appends 3 MB to t6 (compressed write with new extents)
#  5 kernel ntfs: rewrites the middle of t1 (compressed overwrite)
# STAGE_CLUSTER (default 512) selects the cluster size.
. "$HARNESS/guest_lib.sh"
cs=${STAGE_CLUSTER:-512}
img=$W/stages.img; rm -f "$img" "$W"/exp-ext.json "$W"/stage-*.img; truncate -s 64M "$img"
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
stage() {	# stage N: ntfsck, keep a copy, verify all files with ntfs-3g
	echo "### stage $1 done"
	cp --sparse=always "$img" "$W"/stage-"$1".img
	if "$NTFSCK" -n "$img" > "$W"/ntfsck-stage-"$1".log 2>&1; then
		echo "PASS: ntfsck after stage $1"
	else
		fail "ntfsck after stage $1"
		grep -E "Inode|Index|errors" "$W"/ntfsck-stage-"$1".log | head -6
	fi
	mount_drv ntfs-3g "$img" ro && {
		python3 - "$W"/exp-ext.json "$1" <<'PY'
import hashlib, json, sys
for p, m in json.load(open(sys.argv[1])).items():
    try:
        ok = hashlib.sha256(open(p, "rb").read()).hexdigest() == m["sha256"]
        msg = "ok" if ok else "DIFF"
    except OSError as e:
        ok, msg = False, f"ERR {e.strerror}"
    print(("PASS" if ok else "FAIL") + f": stage {sys.argv[2]} ntfs-3g reads {p.rsplit('/', 1)[1]}: {msg}")
PY
		umount "$M"; }
}
mount_drv ntfs-3g "$img" rw || { fail "ntfs-3g mount"; exit; }
chunk=$((2 * cs)); [ $chunk -lt 1024 ] && chunk=1024
python3 "$HARNESS"/make_fragmented.py "$M" $chunk
if ! { mkdir "$M"/comp && setfattr -h -v 0x00000810 -n system.ntfs_attrib_be "$M"/comp; }; then
	fail "set compressed directory"; exit
fi
text "$M"/comp/t1-ntfs3g.txt 3000000 1
text "$M"/comp/t6-ntfs3g-then-ntfs.txt 300000 6
umount "$M"
stage 1
mount_drv ntfs3 "$img" rw && { text "$M"/comp/t2-ntfs3.txt 3000000 2; umount "$M"; }
stage 2
mount_drv ntfs "$img" rw && { text "$M"/comp/t3-ntfs.txt 3000000 3 2>&1 | tail -1; umount "$M"; }
stage 3
mount_drv ntfs "$img" rw && { text "$M"/comp/t6-ntfs3g-then-ntfs.txt 3000000 7 append 2>&1 | tail -1; umount "$M"; }
stage 4
mount_drv ntfs "$img" rw && { python3 - "$M"/comp/t1-ntfs3g.txt "$W"/exp-ext.json <<'PY'
import hashlib, json, sys
p, ef = sys.argv[1], sys.argv[2]
with open(p, "r+b") as f:
    f.seek(1000000); f.write(b"rewritten by the kernel ntfs driver " * 1000)
data = open(p, "rb").read()
e = json.load(open(ef)); e[p] = {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
json.dump(e, open(ef, "w"), indent=1)
PY
umount "$M"; }
stage 5
dmesg | grep -E "ntfs3\(|ntfs:" | grep -v "volume version\|put_super" | head -30
dmesg_check
echo "### done"
