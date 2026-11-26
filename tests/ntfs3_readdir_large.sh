# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): list a directory that does not
# fit in one getdents buffer with ntfs3 and with the kernel ntfs driver, and
# check the names and that lockdep stays quiet (ntfs3 in v7.4-rc1 unlocked
# ni_lock twice whenever the buffer filled up: "bad unlock balance").
# READDIR_FILES (default 3000) files are created with ntfs-3g.
. "$HARNESS/guest_lib.sh"
n=${READDIR_FILES:-3000}
img=$W/readdir.img; rm -f "$img"; truncate -s 64M "$img"
mkntfs -F -Q -q "$img" >/dev/null 2>&1 || { fail "mkntfs"; exit; }
mount_drv ntfs-3g "$img" rw || { fail "ntfs-3g mount"; exit; }
mkdir "$M"/big
python3 -c "import os,sys
for i in range(int(sys.argv[2])): open(os.path.join(sys.argv[1], 'entry-%05d-with-a-longer-name.txt' % i), 'w').close()" "$M"/big "$n"
umount "$M"
for drv in ntfs3 ntfs; do
	mount_drv $drv "$img" ro || { fail "mount $drv"; continue; }
	for _ in 1 2 3; do
		python3 -c "import os,sys
names = os.listdir(sys.argv[1]); want = int(sys.argv[2])
ok = len(names) == want and len(set(names)) == want
print(('PASS' if ok else 'FAIL') + ': %s lists %d of %d names' % (sys.argv[3], len(names), want))" "$M"/big "$n" $drv
	done
	umount "$M"
done
rm -f "$img"
dmesg_check
echo "### done"
