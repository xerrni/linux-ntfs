#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Build a kernel for the test VM from a source tree:
#
#   vm/build_kernel.sh SRC OUT [debug|fast]
#
# Everything the VM needs is built in (virtio, 9p, loop, ntfs, and xfs and
# ext4 for fstests_iomap.sh, xfs with XFS_WARN assertions) except ntfs3,
# which cannot be built in together with ntfs and is installed as a module
# under OUT/modroot. Boot it with
#   KERNEL=OUT/arch/x86/boot/bzImage MODULES=OUT/modroot/lib/modules/VERSION run_vm.sh ...
# "debug" (default) adds KASAN, lockdep, UBSAN and the usual debug checks.
#
# Compiler cache: when ccache is installed, compiles go through it (KCCACHE=0
# turns it off). Kernel builds use their own cache, $KCCACHE_DIR (default
# ~/.cache/ccache-kernel, 25 GiB), set up for btrfs: results are stored and
# fetched as reflinks (file_clone) and left uncompressed, so an object in the
# cache and its copies in build trees share extents, and jdupes -B or any
# other extent deduplication sees plain identical files. On a filesystem
# without reflinks ccache copies instead.
# kbuild passes absolute source paths to the compiler, so trees at different
# paths (worktrees, bisect trees) would never share results. The build
# therefore runs in a private mount namespace (unshare -rm, no root needed)
# where SRC and OUT are bind-mounted at fixed paths under $KBUILD_FIXED_DIR
# (default ~/.cache/kbuild): every tree compiles as the same paths, and a
# second worktree with a few changed files builds in about a minute. Debug
# info and .cmd files then name those fixed paths: rebuild OUT through this
# script only (a plain "make O=OUT" sees changed command lines and recompiles
# everything), and give addr2line/decode_stacktrace.sh the fixed source path.
# Environment: JOBS (default nproc), KCCACHE, KCCACHE_DIR, KBUILD_FIXED_DIR.
#
# Example:
#   vm/build_kernel.sh ../linux ../build-ntfs debug
set -euo pipefail
case "${1:-}" in -h|--help|"") sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0;; esac
src=$(realpath "$1"); out=$(realpath -m "$2"); flavour=${3:-debug}
mkdir -p "$out"
cc=gcc
if [ "${KCCACHE:-1}" != 0 ] && command -v ccache >/dev/null; then
	export CCACHE_DIR=${KCCACHE_DIR:-$HOME/.cache/ccache-kernel}
	mkdir -p "$CCACHE_DIR"
	[ -f "$CCACHE_DIR/ccache.conf" ] || cat > "$CCACHE_DIR/ccache.conf" <<-EOF
		max_size = 25G
		file_clone = true
		compression = false
		sloppiness = time_macros
	EOF
	cc="ccache gcc"
	kb=${KBUILD_FIXED_DIR:-$HOME/.cache/kbuild}
	if [ -z "${KBUILD_REAL_OUT:-}" ] && [ "$src" != "$kb/src" ] && unshare -rm true 2>/dev/null; then
		mkdir -p "$kb/src" "$kb/out"
		export KBUILD_REAL_OUT=$out KBUILD_REAL_SRC=$src
		exec unshare -rm bash -c 'mount --bind "$1" "$3/src" && mount --bind "$2" "$3/out" &&
			exec "$0" "$3/src" "$3/out" "$4"' "$(realpath "$0")" "$src" "$out" "$kb" "$flavour"
	fi
fi
real_out=${KBUILD_REAL_OUT:-$out}
make -C "$src" O="$out" CC="$cc" -s defconfig kvm_guest.config
cfg() { "$src/scripts/config" --file "$out/.config" "$@"; }
cfg -e VIRTIO -e VIRTIO_PCI -e VIRTIO_BLK -e NET_9P -e NET_9P_VIRTIO \
    -e NETFS_SUPPORT -e 9P_FS -e 9P_FS_POSIX_ACL -e BLK_DEV_LOOP \
    -e NTFS_FS -e NTFS_FS_POSIX_ACL -e NTFS_FS_WOF_COMPRESSION -m NTFS3_FS -e NTFS3_LZX_XPRESS -e NTFS3_FS_POSIX_ACL \
    -e DEVTMPFS -e DEVTMPFS_MOUNT -e TMPFS -e FS_POSIX_ACL \
    -e FUSE_FS -e USERFAULTFD -e MAGIC_SYSRQ -e PRINTK_TIME -e MODULES \
    -e MD -e BLK_DEV_DM -e DM_LOG_WRITES -e DM_FLAKEY \
    -e XFS_FS -e XFS_POSIX_ACL -e XFS_QUOTA -e XFS_WARN \
    -e EXT4_FS -e EXT4_FS_POSIX_ACL -e QUOTA -e QFMT_V2
if [ "$flavour" = debug ]; then
	cfg -e KASAN -e KASAN_GENERIC -e KASAN_INLINE -e PROVE_LOCKING \
	    -e DEBUG_ATOMIC_SLEEP -e DEBUG_LIST -e UBSAN -e UBSAN_BOUNDS -e UBSAN_SHIFT \
	    -e DEBUG_KERNEL -e DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
	    -e DETECT_HUNG_TASK -e SOFTLOCKUP_DETECTOR -e BUG_ON_DATA_CORRUPTION \
	    -e DEBUG_VM -e DEBUG_PAGEALLOC -e PAGE_POISONING -e FAULT_INJECTION \
	    -e FAILSLAB -e FAIL_PAGE_ALLOC -e FAULT_INJECTION_DEBUG_FS \
	    -e KFENCE -e PANIC_ON_OOPS
fi
make -C "$src" O="$out" CC="$cc" -s olddefconfig
for o in NTFS_FS=y NTFS3_FS=m 9P_FS=y NET_9P_VIRTIO=y BLK_DEV_LOOP=y XFS_FS=y EXT4_FS=y; do
	grep -q "^CONFIG_$o" "$out/.config" || { echo "CONFIG_$o not enabled" >&2; exit 1; }
done
make -C "$src" O="$out" CC="$cc" -s -j"${JOBS:-$(nproc)}" bzImage modules
make -C "$src" O="$out" CC="$cc" -s INSTALL_MOD_PATH="$out/modroot" modules_install
# modules_install links lib/modules/*/build (and source) to OUT and SRC as
# make saw them: point them at the real paths, not the namespace mounts
for l in "$out"/modroot/lib/modules/*/build "$out"/modroot/lib/modules/*/source; do
	[ -L "$l" ] || continue
	case $(readlink "$l") in
	"$out"*) ln -sfn "$real_out" "$l";;
	"$src"*) ln -sfn "${KBUILD_REAL_SRC:-$src}" "$l";;
	esac
done
[ "$cc" = gcc ] || ccache --show-stats | sed -n 's/^[[:space:]]*Hits:/ccache hits (all builds so far):/p' | head -1
echo "KERNEL=$real_out/arch/x86/boot/bzImage MODULES=$real_out/modroot/lib/modules/$(cat "$out/include/config/kernel.release")"
