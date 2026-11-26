# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): directory operations with the
# kernel ntfs driver inside a compressed directory (made by ntfs-3g with
# system.ntfs_attrib_be 0x810; on NTFS that flag on $INDEX_ROOT only says
# that new files should be compressed). Windows allows all of these.
#  create 200 files (the index root grows, then moves to an index block),
#  write to them, mkdir, rename inside the directory and out of it, unlink,
#  rmdir; then ntfsck -n and read back with ntfs, ntfs-3g and ntfs3.
# The flags of a new file show whether the driver created it compressed.
# DIR_CLUSTER (default 4096) selects the cluster size.
. "$HARNESS/guest_lib.sh"
cs=${DIR_CLUSTER:-4096}
img=$W/cdir-$cs.img; rm -f "$img" "$W"/cdir-exp.json; truncate -s 64M "$img"
mkntfs -F -Q -q -c "$cs" "$img" >/dev/null 2>&1 || { fail "mkntfs"; exit; }
mount_drv ntfs-3g "$img" rw || { fail "ntfs-3g mount"; exit; }
if ! { mkdir "$M"/comp && setfattr -h -v 0x00000810 -n system.ntfs_attrib_be "$M"/comp; }; then
	fail "set compressed directory"; exit
fi
# 8 KiB, so that ntfs-3g stores it non-resident: ntfsck reports the
# resident compressed $DATA that ntfs-3g writes for tiny files
python3 -c "open('$M/comp/old.txt', 'wb').write(b'made by ntfs-3g ' * 512)"
umount "$M"
mount_drv ntfs "$img" rw || { fail "ntfs mount"; exit; }
python3 - "$M"/comp "$W"/cdir-exp.json <<'PY'
import hashlib, json, os, sys
d, ef = sys.argv[1], sys.argv[2]
exp, errs = {}, []
def step(what, fn):
    try:
        fn()
    except OSError as e:
        errs.append(f"{what}: {e.strerror}")
for i in range(200):
    p = os.path.join(d, f"new-{i:03d}-" + "x" * 40 + ".txt")
    data = (f"file {i} " * 50).encode()
    def w(p=p, data=data):
        with open(p, "wb") as f:
            f.write(data)
    step(f"create {i}", w)
    exp[p] = hashlib.sha256(data).hexdigest()
step("mkdir", lambda: os.mkdir(os.path.join(d, "sub")))
step("rename in dir", lambda: os.rename(os.path.join(d, "new-000-" + "x" * 40 + ".txt"), os.path.join(d, "sub", "moved.txt")))
exp[os.path.join(d, "sub", "moved.txt")] = exp.pop(os.path.join(d, "new-000-" + "x" * 40 + ".txt"))
step("rename out", lambda: os.rename(os.path.join(d, "new-001-" + "x" * 40 + ".txt"), os.path.join(d, "..", "out.txt")))
exp[os.path.join(os.path.dirname(d), "out.txt")] = exp.pop(os.path.join(d, "new-001-" + "x" * 40 + ".txt"))
for i in range(2, 100, 2):
    p = os.path.join(d, f"new-{i:03d}-" + "x" * 40 + ".txt")
    step(f"unlink {i}", lambda p=p: os.unlink(p))
    exp.pop(p, None)
step("mkdir2", lambda: os.mkdir(os.path.join(d, "gone")))
step("rmdir", lambda: os.rmdir(os.path.join(d, "gone")))
exp[os.path.join(d, "old.txt")] = hashlib.sha256(b"made by ntfs-3g " * 512).hexdigest()
json.dump(exp, open(ef, "w"))
print(("FAIL" if errs else "PASS") + f": operations in a compressed directory ({len(errs)} errors) {errs[:4]}")
PY
getfattr -h -e hex -n system.ntfs_attrib_be "$M/comp/new-199-$(printf 'x%.0s' $(seq 40)).txt" 2>&1 | tail -1
umount "$M" || fail "umount"
run_ntfsck "$img" cdir-"$cs"
for drv in ntfs ntfs-3g ntfs3; do
	mount_drv $drv "$img" ro || { fail "mount $drv"; continue; }
	python3 - "$W"/cdir-exp.json $drv <<'PY'
import hashlib, json, sys
bad = []
for p, h in json.load(open(sys.argv[1])).items():
    try:
        if hashlib.sha256(open(p, "rb").read()).hexdigest() != h:
            bad.append(p.rsplit("/", 1)[1])
    except OSError as e:
        bad.append(f"{p.rsplit('/', 1)[1]} ({e.strerror})")
print(("FAIL" if bad else "PASS") + f": {sys.argv[2]} reads the directory ({len(bad)} bad) {bad[:4]}")
PY
	umount "$M"
done
dmesg | grep -E "ntfs:|ntfs3\(" | grep -v "volume version\|put_super" | tail -8
dmesg_check
echo "### done"
