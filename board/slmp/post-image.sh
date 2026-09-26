#!/bin/sh
#
# post-image.sh - assemble the disk image and make it bootable.
#
# genimage builds filesystems; it does not make anything bootable. The
# MBR boot code and ldlinux.sys both have to be written explicitly.
#
# Arguments, supplied via BR2_ROOTFS_POST_IMAGE_SCRIPT_ARGS:
#   $1  BINARIES_DIR (passed by Buildroot itself)
#   $2  path to the host syslinux installer, or "none"
#   $3  path to mbr.bin, or "none"
#   $4  path to ldlinux.c32, or "none"
#
# All three come from the same host syslinux install. ldlinux.sys and
# ldlinux.c32 must be the same version or the image builds cleanly and
# then stops at the bootloader prompt, so they are resolved together by
# phase 1.sh and handed down rather than searched for twice.
set -e

BINARIES_DIR="$1"
SYSLINUX_BIN="$2"
SYSLINUX_MBR="$3"
SYSLINUX_C32="$4"

BOARD_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
GENIMAGE_CFG="$BOARD_DIR/genimage.cfg"
GENIMAGE_TMP="${BUILD_DIR}/genimage.tmp"
IMG="${BINARIES_DIR}/sdcard.img"

# Must match `offset = 1M` on the boot partition in genimage.cfg.
# syslinux has to be told where the FAT filesystem starts inside the
# disk image; it cannot work that out for itself.
BOOT_OFFSET=1048576

cp "$BOARD_DIR/syslinux.cfg" "${BINARIES_DIR}/syslinux.cfg"

if [ "$SYSLINUX_C32" != "none" ]; then
	cp "$SYSLINUX_C32" "${BINARIES_DIR}/ldlinux.c32"
else
	# genimage lists ldlinux.c32 among the FAT contents, so it has to
	# exist even when we cannot make the image bootable.
	: > "${BINARIES_DIR}/ldlinux.c32"
fi

rm -rf "$GENIMAGE_TMP"
genimage \
	--rootpath "${TARGET_DIR}" \
	--tmppath "$GENIMAGE_TMP" \
	--inputpath "${BINARIES_DIR}" \
	--outputpath "${BINARIES_DIR}" \
	--config "$GENIMAGE_CFG"

if [ "$SYSLINUX_BIN" = "none" ]; then
	echo "post-image: WARNING: no host syslinux, image is NOT bootable"
	exit 0
fi

# 1. MBR boot code into the first 440 bytes, leaving the partition
#    table intact.
dd if="$SYSLINUX_MBR" of="$IMG" bs=440 count=1 conv=notrunc status=none
echo "post-image: wrote MBR boot code from $SYSLINUX_MBR"

# 2. ldlinux.sys into the FAT filesystem at the boot partition offset.
"$SYSLINUX_BIN" --offset "$BOOT_OFFSET" --install "$IMG"
echo "post-image: installed syslinux at offset $BOOT_OFFSET"
