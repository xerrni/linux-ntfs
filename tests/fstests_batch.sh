# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): fstests with FSTYP=ntfs on
# the kernel driver, by default the tests of fstests/patches (generic/816,
# 817 and 818), in one section per cluster size (512, 4096 and 65536), then
# a dmesg check. Prints one PASS or FAIL line per test and section; a test
# that fstests did not run ("not run") is a FAIL too.
# Environment: FSTESTS (an xfstests tree built with fstests/patches
# applied), FSTESTS_TESTS (the tests to run, default "generic/816
# generic/817 generic/818"). The directory of NTFSCK (ntfsprogs-plus's sbin)
# goes first in PATH: fstests runs mkfs.ntfs and fsck.ntfs from PATH, and
# ntfs-3g's mkfs.ntfs must not take over.
# Results: $W/fstests-results/<section>/ (check.log, result.xml and
# <test>.full and <test>.out.bad of every test).
# SHARD=I/N (tests/run_reproducers.sh sets it) runs only part I of N of the
# section and test pairs; the dmesg check runs in every part.
# shardable
. "$HARNESS/guest_lib.sh"
TESTS=${FSTESTS_TESTS:-generic/816 generic/817 generic/818}
SECTIONS="ntfs_512:512 ntfs_4k:4096 ntfs_64k:65536"
# PAIRS: "section:size:test" this run takes, every Nth from I
PAIRS=
i=0
for s in $SECTIONS; do
	for t in $TESTS; do
		i=$((i + 1))
		[ -z "${SHARD:-}" ] ||
			[ $(((i - 1) % ${SHARD#*/})) = $((${SHARD%/*} - 1)) ] || continue
		PAIRS="$PAIRS $s:$t"
	done
done
if [ -z "$PAIRS" ]; then
	echo "shard $SHARD: no fstests to run"
	dmesg_check
	echo "### done"
	exit 0
fi
if ! [ -x "${FSTESTS:-}/check" ]; then
	fail "no fstests tree at '${FSTESTS:-}' (build xfstests with fstests/patches and set FSTESTS)"
	echo "### done"
	exit 0
fi
sbin=$(dirname "$(command -v "$NTFSCK")")
export PATH=$sbin:$PATH
for p in mkfs.ntfs fsck.ntfs; do
	case $(command -v $p) in
	$sbin/*) echo "$p: $(command -v $p)" ;;
	*) fail "$p is '$(command -v $p)', not the one in $sbin" ;;
	esac
done
mountpoint -q /mnt || mount -t tmpfs -o size=2500m tmpfs /mnt
# check and the tests keep their temporary files in /tmp, which is the
# host's, read-only (TMPDIR does not reach the guest scripts)
mountpoint -q /tmp || mount -t tmpfs -o size=256m tmpfs /tmp
# check and the tests write next to the tree; the host's root is read-only
mkdir -p /mnt/xfstests
tar -C "$FSTESTS" --exclude=.git -cf - . | tar -C /mnt/xfstests -xf -
# a 512 MiB test device and a 1 GiB scratch device (generic/816 fills a
# 512 MiB volume), sparse files on the tmpfs
truncate -s 512M /mnt/test.img
truncate -s 1G /mnt/scratch.img
tdev=$(losetup -f --show /mnt/test.img)
sdev=$(losetup -f --show /mnt/scratch.img)
mkdir -p /mnt/fstests/test /mnt/fstests/scratch
mkfs.ntfs -Q -F -q "$tdev" > /dev/null
# every section sets every option: check carries options over from the
# section before only in some cases
for s in $SECTIONS; do
	cat <<EOF
[${s%%:*}]
FSTYP=ntfs
TEST_DEV=$tdev
TEST_DIR=/mnt/fstests/test
SCRATCH_DEV=$sdev
SCRATCH_MNT=/mnt/fstests/scratch
MKFS_OPTIONS="-c ${s#*:}"
RECREATE_TEST_DEV=true
RESULT_BASE=$W/fstests-results

EOF
done > /mnt/xfstests/local.config
cat /mnt/xfstests/local.config
section_tests() {	# SECTION: the tests of PAIRS in it
	for p in $PAIRS; do
		[ "${p%%:*}" = "$1" ] && echo "${p##*:}"
	done
}
: > "$W"/check.out
for s in $SECTIONS; do
	s=${s%%:*}
	mapfile -t stests < <(section_tests "$s")
	[ ${#stests[@]} -gt 0 ] || continue
	mark "fstests $s:" "${stests[*]}"
	(cd /mnt/xfstests && ./check -s "$s" -R xunit "${stests[@]}") >> "$W"/check.out 2>&1
	echo "check $s exit status $?"
done
cat "$W"/check.out
# one line per test and section, from the xunit report of each section
for s in $SECTIONS; do
	s=${s%%:*}
	mapfile -t stests < <(section_tests "$s")
	[ ${#stests[@]} -gt 0 ] || continue
	python3 - "$W/fstests-results/$s/result.xml" "$s" "${stests[@]}" <<'EOF'
import sys
import xml.etree.ElementTree as ET
path, section, tests = sys.argv[1], sys.argv[2], sys.argv[3:]
try:
    cases = {c.get("name"): c for c in ET.parse(path).getroot().iter("testcase")}
except (OSError, ET.ParseError) as e:
    cases = {}
    print(f"FAIL: fstests {section}: no report ({e})")
for t in tests:
    c = cases.get(t)
    if c is None:
        print(f"FAIL: {t} {section}: did not run")
    elif c.find("skipped") is not None:
        print(f"FAIL: {t} {section}: not run: {c.find('skipped').get('message', '')}")
    elif c.find("failure") is not None or c.find("error") is not None:
        e = c.find("failure") if c.find("failure") is not None else c.find("error")
        print(f"FAIL: {t} {section}: {e.get('message', '')}")
    else:
        print(f"PASS: {t} {section}")
EOF
	for f in "$W"/fstests-results/"$s"/generic/*.out.bad; do
		[ -f "$f" ] || continue
		t=${f##*/}; t=${t%.out.bad}
		echo "--- $s generic/$t: diff of the expected output"
		diff -u /mnt/xfstests/tests/generic/"$t".out "$f" | head -30
	done
done
losetup -d "$tdev" "$sdev"
dmesg_check
echo "### done"
