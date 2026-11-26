# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): write workload on sparse files
# with the kernel ntfs driver, cross-checked with ntfs-3g, ntfs3 and ntfsck.
#  B. each fixture $FIXTURES/c*.img (copied): sparse_ops.py on the fixture's
#     sparse file (compression_unit 4, from ntfs-3g) and on a new kernel-made
#     sparse file; ntfsck -n; read back with ntfs, ntfs3 and ntfs-3g
#  C. fresh volumes for each of $CLUSTERS: ntfs-3g creates a sparse file, a
#     dense file and a sparse named stream (all compression_unit 4 where
#     sparse); the kernel driver writes into holes, extends, punches holes,
#     truncates, fallocates, collapses/inserts ranges on them, makes the dense
#     file sparse and creates new sparse files/streams (compression_unit 0);
#     ntfsck -n; read back with ntfs, ntfs3 (no streams) and ntfs-3g; second
#     kernel round; ntfs-3g writes on top; kernel reads again.
# ntfs3 does not support every fixture (512-byte clusters, compressed files):
# its failures are reported as "XFAIL ntfs3" lines, not FAIL.
. "$HARNESS/guest_lib.sh"
OPS="python3 $HARNESS/sparse_ops.py"
VER="python3 $HARNESS/verify_tree.py"
check_drv() {	# check_drv DRV IMG TAG EXPECT... (main files)  [ADS expect via ADS_EXP]
	local drv=$1 img=$2 tag=$3; shift 3
	mount_drv "$drv" "$img" ro || { fail "$tag mount $drv"; return; }
	mark "$tag verify with $drv"
	local args=() e
	for e in "$@"; do args+=(--expect "$e"); done
	[ "$drv" != ntfs3 ] && [ -n "${ADS_EXP:-}" ] && args+=(--expect "$ADS_EXP")
	[ -n "${FX_MANIFEST:-}" ] && args+=(--manifest "$FX_MANIFEST" --skip "$FX_SKIP")
	if $VER "$M" "${args[@]}"; then echo "PASS: $tag $drv"
	elif [ "$drv" = ntfs3 ]; then echo "XFAIL ntfs3: $tag"
	else fail "$tag $drv"; fi
	umount "$M"
}
for fimg in "$FIXTURES"/c*.img; do
	[ -e "$fimg" ] || { echo "SKIP: no fixture images (set FIXTURES)"; break; }
	fx=$(basename "${fimg%.img}")
	mark "B fixture $fx read-write"
	img=$W/$fx.rw.img; rm -f "$img" "$W"/exp-"$fx".json; cp --sparse=always "$fimg" "$img"
	sp=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['info']['sparse'])" "${fimg%.img}".json)
	cs=$(cluster_size "$img")
	"$NTFSCK" -n "$img" > "$W"/ntfsck-"$fx"-orig.log 2>&1; echo "ntfsck before: rc=$? (pre-existing state of the fixture)"
	cu "$img" /"$sp"
	if mount_drv ntfs "$img" rw; then
		$OPS "$M/$sp" "$cs" 21 "$W"/exp-"$fx".json || fail "B ops $fx"
		$OPS "$M/kernel-new.bin" "$cs" 22 "$W"/exp-"$fx".json --new || fail "B ops new $fx"
		umount "$M" || fail "B umount $fx"
	else fail "B mount $fx"; fi
	cu "$img" /"$sp" /kernel-new.bin
	"$NTFSCK" -n "$img" > "$W"/ntfsck-"$fx".log 2>&1; rc=$?
	grep -E "Inode|errors" "$W"/ntfsck-"$fx"-orig.log > "$W"/ntfsck-"$fx"-orig.sum
	grep -E "Inode|errors" "$W"/ntfsck-"$fx".log > "$W"/ntfsck-"$fx".sum
	if [ $rc = 0 ] || cmp -s "$W"/ntfsck-"$fx"-orig.sum "$W"/ntfsck-"$fx".sum; then
		echo "PASS: ntfsck B $fx (rc=$rc, same as before the writes)"
	else fail "ntfsck B $fx rc=$rc"; tail -5 "$W"/ntfsck-"$fx".log; fi
	for drv in ntfs ntfs3 ntfs-3g; do
		FX_MANIFEST=${fimg%.img}.json FX_SKIP=$sp check_drv $drv "$img" "B $fx" "$W"/exp-"$fx".json
	done
	rm -f "$img"
done
for cs in $CLUSTERS; do
	mark "C cluster $cs"
	img=$W/c-$cs.img; rm -f "$img" "$W"/exp-"$cs"-*.json; truncate -s 512M "$img"
	mkntfs -F -Q -q -c "$cs" "$img" >/dev/null 2>&1 || { fail "mkntfs $cs"; continue; }
	main=$W/exp-$cs-main.json; ads=$W/exp-$cs-ads.json
	mount_drv ntfs-3g "$img" rw || { fail "ntfs-3g mount $cs"; continue; }
	echo hello > "$M"/host.txt
	$OPS "$M"/n3g-sparse.bin "$cs" 31 "$main" --new --simple
	$OPS "$M"/n3g-dense.bin "$cs" 32 "$main" --new --dense
	$OPS "$M"/host.txt:sp "$cs" 33 "$ads" --new --simple
	umount "$M"
	cu "$img" /n3g-sparse.bin /n3g-dense.bin /host.txt
	mark "C cluster $cs: kernel ntfs writes"
	if mount_drv ntfs "$img" rw; then
		$VER / --expect "$main" --expect "$ads" || fail "C $cs pre-read"
		$OPS "$M"/n3g-sparse.bin "$cs" 41 "$main" || fail "C ops n3g-sparse $cs"
		$OPS "$M"/n3g-dense.bin "$cs" 42 "$main" || fail "C ops n3g-dense $cs"
		$OPS "$M"/k-sparse.bin "$cs" 43 "$main" --new || fail "C ops k-sparse $cs"
		$OPS "$M"/host.txt:sp "$cs" 44 "$ads" || fail "C ops stream sp $cs"
		$OPS "$M"/host.txt:knew "$cs" 45 "$ads" --new || fail "C ops stream knew $cs"
		umount "$M" || fail "C umount $cs"
	else fail "C mount $cs"; fi
	cu "$img" /n3g-sparse.bin /n3g-dense.bin /k-sparse.bin /host.txt
	run_ntfsck "$img" c-"$cs"
	for drv in ntfs ntfs3 ntfs-3g; do ADS_EXP=$ads check_drv $drv "$img" "C $cs" "$main"; done
	mark "C cluster $cs: kernel ntfs round 2"
	if mount_drv ntfs "$img" rw; then
		$OPS "$M"/k-sparse.bin "$cs" 51 "$main" || fail "C2 ops k-sparse $cs"
		$OPS "$M"/host.txt:knew "$cs" 52 "$ads" || fail "C2 ops knew $cs"
		$OPS "$M"/n3g-sparse.bin "$cs" 53 "$main" || fail "C2 ops n3g-sparse $cs"
		umount "$M"
	else fail "C2 mount $cs"; fi
	run_ntfsck "$img" c2-"$cs"
	ADS_EXP=$ads check_drv ntfs-3g "$img" "C2 $cs" "$main"
	mark "C cluster $cs: ntfs-3g writes on top"
	if mount_drv ntfs-3g "$img" rw; then
		$OPS "$M"/k-sparse.bin "$cs" 61 "$main" --pwrite-only || fail "C3 ntfs-3g ops $cs"
		$OPS "$M"/host.txt:sp "$cs" 62 "$ads" --pwrite-only || fail "C3 ntfs-3g ops sp $cs"
		umount "$M"
	fi
	ADS_EXP=$ads check_drv ntfs "$img" "C3 $cs" "$main"
	run_ntfsck "$img" c3-"$cs"
	rm -f "$img"
done
dmesg_check
echo "### done"
