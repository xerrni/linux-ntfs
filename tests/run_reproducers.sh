#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Run driver reproducers (guest scripts for run_guest_script.sh) on one
# kernel and print one line per script, in the order given: PASS/FAIL
# counts, run time in seconds and the first FAIL line.
#
#   tests/run_reproducers.sh KERNEL_BUILD_DIR WORKDIR [SCRIPT...]
#
# SCRIPT defaults to every fs/ntfs reproducer in this directory (not the
# ntfs3_* ones, which need a kernel with the fs/ntfs3 series, and not the
# measurement scripts). Each run gets WORKDIR/<script name>/ (shell.log,
# console.log). The C helpers are built first (make -C tests).
# Environment: CLUSTERS, MEM, SMP and TIMEOUT pass through to the VM. JOBS
# (default 1) runs that many VMs at once; each takes MEM and SMP vCPUs.
# SKIP leaves out the scripts it names (e.g. SKIP="fsx_parallel.sh").
# SHARD=I/N runs only shard I of N of the scripts (tests/shard.py picks
# them by run time) and passes SHARD to the guest, where a "# shardable"
# script runs only its part.
# Exit status 1 if any script reported a FAIL or did not finish.
#
# Example:
#   tests/run_reproducers.sh ../build-ntfs /var/tmp/repro short_copy_stale.sh
set -uo pipefail
case "${1:-}" in -h|--help|"") sed -n '3,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0;; esac
here=$(cd "$(dirname "$0")" && pwd)
build=$1; work=$(realpath -m "$2"); shift 2
if [ $# = 0 ]; then
	# the slowest first (minutes each), so that with JOBS > 1 the VMs
	# finish at about the same time
	slow="ntfs_compressed_stages.sh sparse_cu_crafted.sh hole_fill_stale.sh
		sparse_cu_rw.sh stale_wb_race.sh"
	set -- $slow $(cd "$here" && ls delalloc_*.sh hole_fill_stale.sh short_copy_stale.sh \
		short_write_size.sh stale_wb_race.sh slab_cache_names.sh sparse_cu_*.sh fstests_batch.sh \
		ntfs_compressed_*.sh fsx_parallel.sh killed_short_write.sh killed_write_mmap.sh \
		keep_size_short_write.sh stale_write_mapping.sh aio_dio_partial.sh 2>/dev/null | grep -vxF "$(printf '%s\n' $slow)")
fi
if [ -n "${SKIP:-}" ]; then
	keep=()
	for s in "$@"; do
		case " $(echo $SKIP) " in *" ${s##*/} "*) ;; *) keep+=("$s");; esac
	done
	set -- "${keep[@]}"
fi
if [ -n "${SHARD:-}" ]; then
	mine=$(python3 "$here/shard.py" "$SHARD" "$@") || exit 2
	# shellcheck disable=SC2086 # one word per script
	set -- $mine
	export GUEST_ENV="${GUEST_ENV:-} SHARD=$SHARD"
fi
mkdir -p "$work"
make -s -C "$here" || exit 2	# the C helpers
one() {	# one SCRIPT: run it, leave its result line in WORKDIR/NAME.result
	local name=${1%.sh} p f done_ first t0=$SECONDS
	name=${name##*/}
	"$here/run_guest_script.sh" "$build" "$work/$name" "$here/${1##*/}" > "$work/$name.log" 2>&1
	local log=$work/$name/shell.log
	p=$(grep -c '^PASS' "$log" 2>/dev/null); f=$(grep -c '^FAIL' "$log" 2>/dev/null)
	done_=$(grep -c '^### done' "$log" 2>/dev/null)
	first=$(grep -m1 '^FAIL' "$log" 2>/dev/null)
	[ "${done_:-0}" -gt 0 ] || first="did not finish (see $work/$name.log)"
	printf '%-32s pass %3s fail %3s %4ss %s\n' "$name" "${p:-0}" "${f:-0}" \
		$((SECONDS - t0)) "$first" > "$work/$name.result.tmp"
	if [ "${done_:-0}" = 0 ]; then	# why, on stderr: stdout is the result list
		for o in "$work/$name.log" "$work/$name/run.out"; do
			[ -s "$o" ] && sed "s|^|  $name ${o##*/}: |" "$o" | tail -n 15 >&2
		done
	fi
	mv "$work/$name.result.tmp" "$work/$name.result"
}
names=()
for s in "$@"; do n=${s%.sh}; names+=("${n##*/}"); rm -f "$work/${n##*/}.result"; done
next=0
flush() {	# print the finished results that come next in order
	while [ $next -lt ${#names[@]} ] && [ -f "$work/${names[$next]}.result" ]; do
		cat "$work/${names[$next]}.result"
		next=$((next + 1))
	done
}
for s in "$@"; do
	while [ "$(jobs -rp | wc -l)" -ge "${JOBS:-1}" ]; do wait -n; flush; done
	one "$s" &
done
wait
flush
fail=0
for n in "${names[@]}"; do
	grep -qE ' fail +0 +[0-9]+s $' "$work/$n.result" || fail=1
done
exit $fail
