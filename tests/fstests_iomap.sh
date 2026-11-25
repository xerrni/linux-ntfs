# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): fstests on XFS and ext4,
# for the iomap buffered write path that delalloc punch takes after a short
# or failed write. Not in the default test list; run it by name
# (test-kernel.yml: tests=fstests_iomap, about an hour per two sections on
# the fast kernel). Sections: xfs_1k and xfs_4k (mkfs.xfs -b size=1024 and
# 4096), ext4_1k and ext4_4k (mkfs.ext4 -b 1024 and 4096, mounted with
# buffered_iomap: without it ext4 does not use iomap for buffered writes).
# Tests: the quick tests of generic/ and of the file system's own directory
# in the groups rw, punch, prealloc, enospc, mmap, quota, zero, collapse and
# insert, without those also in a group that does not reach buffered writes
# (clone, dedupe, aio, fiemap, swap, encrypt, verity, casefold, idmapped,
# attr, acl) or that is slow or destructive (dangerous, stress, soak,
# long_rw, recoveryloop), plus the fsx tests generic/075, 091, 112, 127, 263
# and 469 and generic/816 to 818. Prints PASS, FAIL and NOTRUN lines per test
# and section (NOTRUN is not counted) and one summary line per section.
# Environment: FSTESTS (an xfstests tree built with fstests/patches),
# FSTESTS_SECTIONS (comma separated, default all four), FSTESTS_TESTS
# (replaces the computed list), FSTESTS_SECTION_TIMEOUT (seconds a section
# may take, default 3000), FSTESTS_TEST_SIZE and FSTESTS_SCRATCH_SIZE (loop
# devices on a tmpfs, default 2G and 3G; give the VM MEM=8G).
# Results: $W/fstests-results/<section>/.
. "$HARNESS/guest_lib.sh"
SECTIONS=$(echo "${FSTESTS_SECTIONS:-xfs_1k,xfs_4k,ext4_1k,ext4_4k}" | tr , ' ')
STIMEOUT=${FSTESTS_SECTION_TIMEOUT:-3000}
if ! [ -x "${FSTESTS:-}/check" ]; then
	fail "no fstests tree at '${FSTESTS:-}' (build xfstests with fstests/patches and set FSTESTS)"
	echo "### done"
	exit 0
fi
echo "memory: $(awk '/MemTotal/{print $2 " kB"}' /proc/meminfo), cpus: $(nproc)"
mountpoint -q /mnt || mount -t tmpfs -o size=90% tmpfs /mnt
# check and the tests keep their temporary files in /tmp, which is the
# host's, read-only (TMPDIR does not reach the guest scripts)
mountpoint -q /tmp || mount -t tmpfs -o size=512m tmpfs /tmp
mkdir -p /mnt/xfstests
tar -C "$FSTESTS" --exclude=.git -cf - . | tar -C /mnt/xfstests -xf -
truncate -s "${FSTESTS_TEST_SIZE:-2G}" /mnt/test.img
truncate -s "${FSTESTS_SCRATCH_SIZE:-3G}" /mnt/scratch.img
tdev=$(losetup -f --show /mnt/test.img)
sdev=$(losetup -f --show /mnt/scratch.img)
mkdir -p /mnt/fstests/test /mnt/fstests/scratch
for p in mkfs.xfs xfs_io xfs_repair mkfs.ext4 e2fsck; do
	command -v $p > /dev/null || fail "no $p"
done
mkfs.xfs -V; mkfs.ext4 -V 2>&1 | head -1
tests_for() {	# tests_for FSTYP: the computed test list
	(cd /mnt/xfstests/tests && grep -H '^_begin_fstest' generic/[0-9]* $1/[0-9]* 2>/dev/null) |
	awk '{
		q = 0; io = 0; bad = 0
		for (i = 2; i <= NF; i++) {
			if ($i == "quick") q = 1
			if ($i ~ /^(rw|punch|prealloc|enospc|mmap|quota|zero|collapse|insert)$/) io = 1
			if ($i ~ /^(clone.*|dedupe|aio|fiemap|swap|encrypt|verity|casefold|idmapped|attr|acl)$/) bad = 1
			if ($i ~ /^(dangerous.*|stress|soak|long_rw|recoveryloop)$/) bad = 1
		}
		sub(/:.*/, "", $1)
		if (q && io && !bad) print $1
	}'
	printf 'generic/%s\n' 075 091 112 127 263 469 816 817 818
}
for sec in $SECTIONS; do
	case $sec in
	xfs_1k) fs=xfs; mkfs="-b size=1024"; mnt="" ;;
	xfs_4k) fs=xfs; mkfs="-b size=4096"; mnt="" ;;
	ext4_1k) fs=ext4; mkfs="-b 1024"; mnt="-o buffered_iomap" ;;
	ext4_4k) fs=ext4; mkfs="-b 4096"; mnt="-o buffered_iomap" ;;
	*) fail "unknown section $sec"; continue ;;
	esac
	cat > /mnt/xfstests/local.config <<EOF
[$sec]
FSTYP=$fs
TEST_DEV=$tdev
TEST_DIR=/mnt/fstests/test
SCRATCH_DEV=$sdev
SCRATCH_MNT=/mnt/fstests/scratch
MKFS_OPTIONS="$mkfs"
MOUNT_OPTIONS="$mnt"
TEST_FS_MOUNT_OPTS="$mnt"
RECREATE_TEST_DEV=true
RESULT_BASE=$W/fstests-results
EOF
	cat /mnt/xfstests/local.config
	list=${FSTESTS_TESTS:-$(tests_for $fs | sort -u | tr '\n' ' ')}
	echo "tests of $sec ($(echo $list | wc -w)): $list"
	mark "fstests $sec"
	t0=$SECONDS
	(cd /mnt/xfstests && timeout -k 60 "$STIMEOUT" ./check -s $sec -R xunit $list) > $W/check-$sec.out 2>&1
	rc=$?
	echo "check $sec: exit status $rc after $((SECONDS - t0)) s"
	[ $rc = 124 ] && fail "fstests $sec: stopped after $STIMEOUT s"
	umount /mnt/fstests/scratch /mnt/fstests/test 2>/dev/null
	tail -n 8 $W/check-$sec.out
	python3 - "$W/fstests-results/$sec/result.xml" "$sec" $list <<'EOF'
import sys
import xml.etree.ElementTree as ET
path, section, tests = sys.argv[1], sys.argv[2], sys.argv[3:]
try:
    cases = {c.get("name"): c for c in ET.parse(path).getroot().iter("testcase")}
except (OSError, ET.ParseError) as e:
    cases = {}
    print(f"FAIL: fstests {section}: no report ({e})")
n = {"pass": 0, "fail": 0, "notrun": 0}
for t in tests:
    c = cases.get(t)
    if c is None:
        print(f"FAIL: {t} {section}: did not run")
        n["fail"] += 1
    elif c.find("skipped") is not None:
        print(f"NOTRUN: {t} {section}: {c.find('skipped').get('message', '')}")
        n["notrun"] += 1
    elif c.find("failure") is not None or c.find("error") is not None:
        e = c.find("failure") if c.find("failure") is not None else c.find("error")
        print(f"FAIL: {t} {section}: {e.get('message', '')}")
        n["fail"] += 1
    else:
        print(f"PASS: {t} {section} {c.get('time', '')}s")
        n["pass"] += 1
print(f"### section {section}: {n['pass']} pass, {n['fail']} fail, {n['notrun']} not run")
EOF
	for f in "$W"/fstests-results/$sec/*/*.out.bad; do
		[ -f "$f" ] || continue
		t=${f#$W/fstests-results/$sec/}; t=${t%.out.bad}
		echo "--- $sec $t: diff of the expected output"
		diff -u /mnt/xfstests/tests/$t.out "$f" | head -n 20
	done
done
dmesg | grep -m2 -E "SGI XFS with|EXT4-fs.*buffered_iomap"
losetup -d "$tdev" "$sdev"
dmesg_check
echo "### done"
