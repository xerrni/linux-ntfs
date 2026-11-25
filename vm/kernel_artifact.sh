#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Pack what the test VM needs from a vm/build_kernel.sh OUT directory into
# one file, or unpack such a file into a new OUT directory, so that a CI job
# builds the kernel once and every test job boots the same build:
#
#   vm/kernel_artifact.sh pack OUT FILE [SRC]
#   vm/kernel_artifact.sh unpack FILE OUT
#
# The file holds arch/x86/boot/bzImage, modroot/ and
# include/config/kernel.release, which is all tests/run_guest_script.sh
# reads, plus commits.txt: the last 50 commits of the kernel source tree
# SRC (the base and the patches applied on it) when SRC is given.
# The bzImage does not depend on the distribution the tests run on: the
# guest uses the host's root file system, not the build host's.
#
# Example:
#   vm/kernel_artifact.sh pack ../build-ntfs /var/tmp/kernel.tar ../ntfs
set -euo pipefail
case "${1:-}" in -h|--help|"") sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0;; esac
case $1 in
pack)
	out=$2 file=$3 src=${4:-}
	if [ -n "$src" ]; then
		git -C "$src" log --format='%h %s' -n 50 > "$out/commits.txt"
	else
		: > "$out/commits.txt"
	fi
	tar -C "$out" -cf "$file" arch/x86/boot/bzImage modroot \
		include/config/kernel.release commits.txt
	;;
unpack)
	file=$2 out=$3
	mkdir -p "$out"
	tar -C "$out" -xf "$file"
	test -f "$out/arch/x86/boot/bzImage"
	;;
*)
	echo "unknown command $1 (pack or unpack)" >&2
	exit 2
	;;
esac
