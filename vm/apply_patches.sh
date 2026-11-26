#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Apply patches, in the order given, as commits on top of a kernel git tree:
#
#   vm/apply_patches.sh SRC PATCH...
#
# PATCH is one of:
#   - a lore message id (<id@host> or id@host) or a lore.kernel.org link to
#     a message: b4 fetches the whole series that message belongs to, with
#     its trailers, and git am applies it (needs b4);
#   - an http(s) URL of an mbox, a git format-patch file or a plain diff;
#   - a local file of the same kinds (relative to the current directory).
# Mail-formatted files go through git am; a plain diff is applied with git
# apply and committed as "Apply <file name>". A patch that is already in
# SRC (same git patch-id as one of its last 300 commits) is skipped, so a
# second run does nothing. Without a git identity in SRC the commits are
# made as apply_patches.
# Prints the commits it added. Exit status 1 when a patch does not apply
# (SRC is left at the last patch that did).
#
# Example:
#   vm/apply_patches.sh ../ntfs 20261120023504.4134966-1-zhanxusheng1024@gmail.com \
#       patches/v8-zero-for-a-killed-writer.diff
set -euo pipefail
case "${1:-}" in -h|--help|"") sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0;; esac
src=$1; shift
git -C "$src" rev-parse --git-dir >/dev/null
if ! git -C "$src" config user.email >/dev/null; then
	export GIT_AUTHOR_NAME=apply_patches GIT_AUTHOR_EMAIL=apply_patches@localhost
	export GIT_COMMITTER_NAME=apply_patches GIT_COMMITTER_EMAIL=apply_patches@localhost
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
base=$(git -C "$src" rev-parse HEAD)
n=0
for p in "$@"; do
	n=$((n + 1))
	f=$tmp/$n.patch
	case $p in
	https://lore.kernel.org/*|http://lore.kernel.org/*)
		id=$(echo "$p" | sed -E 's|^https?://lore.kernel.org/[^/]+/([^/]+).*|\1|')
		b4 -q am -o - "$id" > "$f" ;;
	http://*|https://*)
		curl -fsSL -o "$f" "$p" ;;
	*@*)
		if [ -f "$p" ]; then cp "$p" "$f"; else b4 -q am -o - "${p//[<>]/}" > "$f"; fi ;;
	*)
		cp "$p" "$f" ;;
	esac
	# already applied: every patch in it has the patch-id of a recent commit
	want=$(git -C "$src" patch-id --stable < "$f" | awk '{print $1}' | sort -u)
	have=$(git -C "$src" log -n 300 -p --format='commit %H' | git -C "$src" patch-id --stable |
		awk '{print $1}' | sort -u)
	if [ -n "$want" ] && [ -z "$(comm -23 <(echo "$want") <(echo "$have"))" ]; then
		echo "already applied, skipped: $p"
		continue
	fi
	if grep -qm1 -E '^From: ' "$f"; then
		git -C "$src" am -q "$f" || { git -C "$src" am --abort; echo "does not apply: $p" >&2; exit 1; }
	else
		git -C "$src" apply --index "$f" || { echo "does not apply: $p" >&2; exit 1; }
		git -C "$src" commit -q -m "Apply ${p##*/}"
	fi
done
git -C "$src" log --oneline "$base..HEAD"
