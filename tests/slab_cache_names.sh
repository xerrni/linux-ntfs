# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): every slab cache name must be
# unique once both NTFS drivers are loaded (ntfs built in or loaded, ntfs3
# loaded by the VM init), and creating them must not have triggered
# "kmem_cache of name '...' already exists" (CONFIG_DEBUG_VM). Also mounts a
# volume with each driver so their caches are in use.
. "$HARNESS/guest_lib.sh"
grep -wE "ntfs|ntfs3" /proc/filesystems
img=$W/slab.img; rm -f "$img"; truncate -s 64M "$img"
mkntfs -F -Q -q "$img" >/dev/null 2>&1
for drv in ntfs ntfs3; do
	if mount_drv $drv "$img" rw; then
		echo x > "$M"/f-$drv; umount "$M"
	else
		fail "mount $drv"
	fi
done
rm -f "$img"
grep -E "^ntfs" /proc/slabinfo | awk '{print $1}'
dup=$(awk 'NR > 2 {print $1}' /proc/slabinfo | sort | uniq -d)
if [ -n "$dup" ]; then fail "duplicate slab cache names: $dup"; else echo "PASS: slab cache names unique"; fi
w=$(dmesg | grep "kmem_cache of name")
if [ -n "$w" ]; then fail "duplicate cache warning: $w"; else echo "PASS: no duplicate cache warning"; fi
dmesg_check
echo "### done"
