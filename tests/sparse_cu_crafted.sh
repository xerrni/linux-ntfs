# SPDX-License-Identifier: GPL-2.0-or-later
# Guest script (run with run_guest_script.sh): kernel ntfs driver on images
# whose sparse $DATA attributes carry unusual compression_unit values (set
# with set_compression_unit.py), for the unnamed stream and a named stream,
# on 4K and 64K clusters. Expected (with the sparse-cu validation fix): values
# 0, 4 and the volume's sparse unit open, anything else is refused with
# "Found non-standard compression unit" for named and unnamed streams alike,
# and no UBSAN shift-out-of-bounds (build with CONFIG_UBSAN_SHIFT to see it).
# Mounted read-write: a refused value must not leave the volume marked dirty.
# CRAFT_CLUSTERS / CRAFT_VALUES override the defaults.
. "$HARNESS/guest_lib.sh"
for cs in ${CRAFT_CLUSTERS:-4096 65536}; do
	base=$W/d-$cs.img; rm -f "$base" "$W"/exp-d-"$cs".json; truncate -s 256M "$base"
	mkntfs -F -Q -q -c "$cs" "$base" >/dev/null 2>&1
	mount_drv ntfs-3g "$base" rw || { fail "ntfs-3g $cs"; continue; }
	echo hello > "$M"/host.txt
	python3 "$HARNESS"/sparse_ops.py "$M"/sparse.bin "$cs" 71 "$W"/exp-d-"$cs".json --new --simple
	python3 "$HARNESS"/sparse_ops.py "$M"/host.txt:sp "$cs" 72 "$W"/exp-d-"$cs".json --new --simple
	umount "$M"
	ino_s=$(mft_no "$base" /sparse.bin); ino_h=$(mft_no "$base" /host.txt)
	for which in named unnamed; do
		for v in ${CRAFT_VALUES:-0 1 2 3 4 20 31 200}; do
			img=$W/d-$cs-$which-$v.img; cp --sparse=always "$base" "$img"
			if [ $which = named ]; then ino=$ino_h; f=$M/host.txt:sp; else ino=$ino_s; f=$M/sparse.bin; fi
			python3 "$HARNESS"/set_compression_unit.py "$img" "$ino" "$v" $which
			mark "D cluster $cs $which cu=$v"
			if mount_drv ntfs "$img" rw; then
				python3 -c "import sys;print('RESULT cluster=%s %s cu=%s: read %d bytes' % (sys.argv[2], sys.argv[3], sys.argv[4], len(open(sys.argv[1],'rb').read())))" "$f" "$cs" $which "$v" 2>&1 | tail -1
				umount "$M"
				# a refused (unsupported) value must not leave the volume dirty
				vf=$(python3 "$HARNESS"/volume_flags.py "$img")
				echo "RESULT cluster=$cs $which cu=$v: volume flags after rw mount $vf"
				[ -n "$vf" ] && [ $(( vf & 1 )) = 0 ] || fail "volume left dirty, flags '$vf' (cluster=$cs $which cu=$v)"
			fi
			dmesg | sed -n "/### D cluster $cs $which cu=$v\$/,\$p" | grep -E "compression unit|UBSAN|shift" | head -5
			rm -f "$img"
		done
	done
	rm -f "$base"
done
dmesg_check
echo "### done"
