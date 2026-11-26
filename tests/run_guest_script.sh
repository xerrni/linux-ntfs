#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Boot a kernel in QEMU (via vm/run_vm.sh + vm/vm_shell.py) and run one bash
# guest script as root in it, with the host root mounted read-only and WORKDIR
# writable at the same path.
#
#   tests/run_guest_script.sh KERNEL_BUILD_DIR|distro WORKDIR GUEST_SCRIPT
#
# KERNEL_BUILD_DIR is an OUT directory of vm/build_kernel.sh (bzImage +
# modroot); "distro" boots /boot/vmlinuz-linux with the newest modules in
# /usr/lib/modules. The guest script gets these variables (override from the
# environment): HARNESS (this directory), NTFSCK, NTFSINFO (ntfsprogs-plus
# tools, default: found in PATH), FIXTURES (directory of extra NTFS images
# c*.img for the sparse_cu tests, default none: those parts are skipped),
# XFSTESTS (an xfstests checkout with fsx built, for fsx_parallel.sh),
# FSTESTS (a built xfstests tree with fstests/patches, for fstests_batch.sh),
# CLUSTERS (default
# "512 4096 16384 65536"), DMESG_IGNORE (see guest_lib.sh) and may source
# guest_lib.sh. GUEST_ENV="VAR=value ..." exports more variables to the
# guest script (e.g. GUEST_ENV="STAGE_CLUSTER=4096").
# Output: WORKDIR/shell.log (bash -x of the guest script), WORKDIR/console.log.
#
# Example:
#   tests/run_guest_script.sh ../build-ntfs /var/tmp/short tests/short_write_size.sh
set -euo pipefail
case "${1:-}" in -h|--help|"") sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0;; esac
here=$(cd "$(dirname "$0")" && pwd)
vm=$(cd "$here/../vm" && pwd)
build=$1; work=$(realpath -m "$2"); script=$(realpath "$3")
ntfsck=${NTFSCK:-$(command -v ntfsck || echo ntfsck)}
ntfsinfo=${NTFSINFO:-$(command -v ntfsinfo || echo ntfsinfo)}
mkdir -p "$work"
rm -f "$work/shell.log" "$work/console.log"
cat > "$work/cmds.sh" <<EOT
export HARNESS=$here
export NTFSCK=$ntfsck
export NTFSINFO=$ntfsinfo
export FIXTURES=${FIXTURES:-}
export XFSTESTS=${XFSTESTS:-}
export FSTESTS=${FSTESTS:-}
export CLUSTERS="${CLUSTERS:-512 4096 16384 65536}"
export DMESG_IGNORE="${DMESG_IGNORE:-}"
$(for kv in ${GUEST_ENV:-}; do printf 'export %q\n' "$kv"; done)
cd $work
. $script
EOT
if [ "$build" = distro ]; then
	unset KERNEL MODULES
else
	build=$(realpath "$build")
	export KERNEL="$build/arch/x86/boot/bzImage"
	# the modules of this kernel; older releases may sit next to them
	MODULES="$build/modroot/lib/modules/$(cat "$build/include/config/kernel.release")"
	export MODULES
fi
SCRIPT="$vm/vm_shell.py" TIMEOUT=${TIMEOUT:-2400} \
	"$vm/run_vm.sh" "$work" > "$work/run.out" 2>&1 || true
grep -E "^(FAIL|PASS|### done)" "$work/shell.log" || true
grep -cE "^FAIL" "$work/shell.log" >/dev/null && exit 1 || exit 0
