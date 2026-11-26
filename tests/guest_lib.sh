# SPDX-License-Identifier: GPL-2.0-or-later
# Helpers for guest scripts run by run_guest_script.sh (source it).
# Mount point: $W/mnt. Kernel driver: always "mount -i -t ntfs" (plain
# "mount -t ntfs" would run the ntfs-3g helper).
# The VM has no /dev/fd, so process substitution (<(...)) fails in guest
# scripts; read command output with a here-string: read -ra x <<< "$(cmd)".
set +e
W=$PWD
M=$W/mnt
mkdir -p "$M"
echo "### kernel $(uname -r)"
fail() { echo "FAIL: $*"; }
mkntfs() {	# the scripts hide its output: keep it in $W/mkntfs-errors.log on failure
	local out rc
	out=$(command mkntfs "$@" 2>&1); rc=$?
	[ $rc = 0 ] || printf 'mkntfs %s: exit %s\n%s\n' "$*" $rc "$out" >> "$W/mkntfs-errors.log"
	printf '%s' "$out"
	[ -z "$out" ] || echo
	return $rc
}
mark() { echo "### $*"; echo "### $*" > /dev/kmsg; }
cluster_size() {	# cluster_size IMG
	python3 -c "import struct,sys;b=open(sys.argv[1],'rb').read(512);s=b[13];print(struct.unpack_from('<H',b,11)[0]*((1<<(256-s)) if s>128 else s))" "$1"
}
cu() {	# cu IMG PATH...: flags and compression unit of the $DATA attributes
	local img=$1; shift
	for p in "$@"; do
		echo "--- \$DATA of $p"
		"$NTFSINFO" -F "$p" "$img" 2>&1 | awk '/Dumping attribute \$DATA/{d=1} /Dumping attribute/&&!/\$DATA/{d=0} d&&/Attribute name|Attribute flags|Compression unit|Data size|Allocated size|Compressed size/{print}'
	done
}
mft_no() {	# mft_no IMG PATH
	"$NTFSINFO" -F "$2" "$1" | awk '/Dumping Inode/{print $3; exit}'
}
mount_drv() {	# mount_drv ntfs|ntfs3|ntfs-3g IMG [ro|rw]
	local o=${3:-rw}
	case $1 in
	ntfs)	mount -i -t ntfs -o "$o",loop,streams_interface=windows "$2" "$M" ;;
	ntfs3)	mount -i -t ntfs3 -o "$o",loop "$2" "$M" ;;
	ntfs-3g) ntfs-3g -o "$o",streams_interface=windows "$2" "$M" ;;
	esac
}
run_ntfsck() {	# run_ntfsck IMG TAG: ntfsck -n, PASS/FAIL line, log in $W/ntfsck-TAG.log
	"$NTFSCK" -n "$1" > "$W/ntfsck-$2.log" 2>&1
	local rc=$?
	if [ $rc = 0 ]; then echo "PASS: ntfsck $2"; else fail "ntfsck $2 rc=$rc"; tail -4 "$W/ntfsck-$2.log"; fi
}
dmesg_check() {	# sanitizer / lockdep / warning reports since boot -> FAIL
	# DMESG_IGNORE: extended regex of known, unrelated report lines to skip.
	# CPU vulnerability notices at boot (they link to admin-guide/hw-vuln)
	# are not reports.
	local r
	r=$(dmesg | grep -E "KASAN|UBSAN|BUG:|WARNING:|possible circular|possible recursive|inconsistent lock|Oops|general protection|shift-out-of-bounds|INFO: task|kmemleak" | grep -v "### " | grep -v "admin-guide/hw-vuln")
	[ -n "${DMESG_IGNORE:-}" ] && r=$(echo "$r" | grep -vE "$DMESG_IGNORE")
	if [ -n "$r" ]; then fail "dmesg reports"; echo "$r" | head -40; else echo "PASS: dmesg clean"; fi
	# lockdep switches itself off after its first report (or never ran)
	[ -r /proc/lockdep_stats ] && grep -E "debug_locks:" /proc/lockdep_stats
}
