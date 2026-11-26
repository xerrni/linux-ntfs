#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Boot a kernel in QEMU and run one Python script in it:
#
#   vm/run_vm.sh WORKDIR
#
# KERNEL is the bzImage to boot (default /boot/vmlinuz-linux) and MODULES its
# modules directory (default /usr/lib/modules/<newest>), from which 9p,
# virtio, loop, ntfs and ntfs3 are loaded when they are modules; "none" when
# everything needed is built in. The guest mounts the host's root file system
# read-only over virtio-9p and WORKDIR writable at the same path, chroots into
# it and runs SCRIPT with python3 and WORKDIR as its argument (default
# vm/vm_shell.py, which runs WORKDIR/cmds.sh with bash): the tests use the
# host's own tools, so the guest gets the host's CPU model (-cpu host).
# On QEMU's default qemu64 model, code that uses AVX dies with SIGILL, as
# the init program does when linked with Ubuntu 26.04's static glibc.
# The guest boots with mitigations=off. With the host's CPU model it would
# otherwise turn on speculation mitigations, which cost a lot in a nested VM
# and do not matter to the tests.
# MEM (3G), SMP (2), TIMEOUT (1800 s) and APPEND (more of the
# kernel command line) size the VM. Needs KVM access and gcc with a static
# libc (for the init program), not root. Output: WORKDIR/console.log.
#
# Example:
#   KERNEL=../build/arch/x86/boot/bzImage MODULES=none vm/run_vm.sh /var/tmp/vmtest
set -euo pipefail
case "${1:-}" in -h|--help|"") sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0;; esac

work=$(realpath -m "$1")
here=$(cd "$(dirname "$0")" && pwd)
kver=${KVER:-$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort -V | tail -n 1 || true)}	# none in a container
kernel=${KERNEL:-/boot/vmlinuz-linux}
mods=${MODULES:-/usr/lib/modules/$kver}
mkdir -p "$work"
script=$(realpath "${SCRIPT:-$here/vm_shell.py}")

# --- initramfs ------------------------------------------------------------
ird=$(mktemp -d)
trap 'rm -rf "$ird"' EXIT
mkdir -p "$ird"/{m,proc,sys,dev,host}
gcc -static -O2 -o "$ird/init" "$here/init.c"
[ "$mods" = none ] || for m in fs/netfs/netfs net/9p/9pnet net/9p/9pnet_virtio fs/9p/9p \
	 drivers/block/loop fs/ntfs/ntfs fs/ntfs3/ntfs3; do
	src=$mods/kernel/$m.ko
	if [ ! -e "$src" ] && [ ! -e "$src.zst" ] && [ ! -e "$src.xz" ]; then continue	# built in
	elif [ -f "$src.zst" ]; then zstd -q -d -c "$src.zst" > "$ird/m/$(basename "$m").ko"
	elif [ -f "$src.xz" ]; then xz -d -c "$src.xz" > "$ird/m/$(basename "$m").ko"
	else cp "$src" "$ird/m/"; fi
done
(cd "$ird" && find . | cpio -o -H newc --quiet) > "$work/initramfs.cpio"

# --- boot ---------------------------------------------------------------------
timeout "${TIMEOUT:-1800}" qemu-system-x86_64 -enable-kvm -cpu host -m "${MEM:-3G}" -smp "${SMP:-2}" -nographic -no-reboot \
	-kernel "$kernel" -initrd "$work/initramfs.cpio" \
	-append "console=ttyS0 panic=-1 loglevel=4 mitigations=off ${APPEND:-} ntfsvm.work=$work ntfsvm.script=$script" \
	-virtfs local,path=/,mount_tag=root,security_model=none,readonly=on,multidevs=remap \
	-virtfs local,path="$work",mount_tag=work,security_model=none,multidevs=remap \
	| tee "$work/console.log" | grep -E '^\{|init:|BUG|Oops|ntfs' || true
