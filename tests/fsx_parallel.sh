# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): xfstests' fsx, several
# instances in parallel on one fresh volume per cluster size of $CLUSTERS,
# then ntfsck -n and a dmesg check.
# Environment: FSX (default: $XFSTESTS/ltp/fsx, or fsx in PATH),
# FSX_JOBS (parallel instances, default 4), FSX_OPS (operations each, default
# 40000), FSX_ARGS (extra fsx options, default "-l 1048576 -o 65536").
# Without fsx the script FAILs rather than skip: a skipped run looked like a
# pass in the results. Leave it out with SKIP="fsx_parallel.sh" instead.
. "$HARNESS/guest_lib.sh"
FSX=${FSX:-${XFSTESTS:+$XFSTESTS/ltp/fsx}}
FSX=${FSX:-$(command -v fsx || echo fsx)}
if ! [ -x "$FSX" ]; then
	fail "no fsx at '$FSX' (build xfstests and set XFSTESTS, or set FSX)"
	echo "### done"
	exit 0
fi
FSX_JOBS=${FSX_JOBS:-4}
FSX_OPS=${FSX_OPS:-40000}
FSX_ARGS=${FSX_ARGS:--l 1048576 -o 65536}
read -ra fsx_args <<< "$FSX_ARGS"
mountpoint -q /mnt || mount -t tmpfs -o size=1500m tmpfs /mnt
IMG=/mnt/fsx.img
for cs in $CLUSTERS; do
	mark "fsx x$FSX_JOBS c$cs"
	rm -f $IMG; truncate -s 256M $IMG
	mkntfs -F -Q -q -c "$cs" $IMG >/dev/null 2>&1 || { fail "mkntfs $cs"; continue; }
	mount -i -t ntfs -o loop $IMG "$M" || { fail "mount $cs"; continue; }
	# the operations fsx leaves out because the volume refuses them (only
	# printed without -q): one operation on a scratch file
	$FSX -N 1 -P "$W" "$M"/fsx.probe 2>&1 | grep "disabling" | sed "s/^/c$cs: /"
	rm -f "$M"/fsx.probe
	pids=""; bad=0
	for j in $(seq 1 "$FSX_JOBS"); do
		$FSX -q -N "$FSX_OPS" -S $((cs + j)) "${fsx_args[@]}" -P "$W" "$M"/fsx."$j" > "$W"/fsx-c"$cs"-"$j".out 2>&1 &
		pids="$pids $!"
	done
	for p in $pids; do wait "$p" || { bad=1; fail "fsx c$cs (pid $p), see $W/fsx-c$cs-*.out"; }; done
	grep -l "^LOG DUMP\|FAIL\|failed" "$W"/fsx-c"$cs"-*.out 2>/dev/null | head -3
	# each instance ends with "All N operations completed A-OK!"
	grep -h "operations completed A-OK" "$W"/fsx-c"$cs"-*.out
	ok=$(cat "$W"/fsx-c"$cs"-*.out | grep -c "operations completed A-OK")
	[ "$ok" = "$FSX_JOBS" ] || { bad=1; fail "fsx c$cs: $ok of $FSX_JOBS instances completed"; }
	echo "free after fsx: $(stat -f -c %f "$M")"
	umount "$M"
	run_ntfsck $IMG "fsx-c$cs"
	[ $bad = 0 ] && echo "PASS: fsx x$FSX_JOBS c$cs, $FSX_OPS operations each"
done
rm -f $IMG
dmesg_check
echo "### done"
