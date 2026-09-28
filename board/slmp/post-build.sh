#!/bin/sh
#
# post-build.sh - cross-compile the front panel link into the target.
#
# Runs after the toolchain exists but before the rootfs is packed, which
# is why this is a post-BUILD and not a post-image script.
#
# Buildroot invokes this by its path inside the Buildroot tree, where
# board/slmp is a symlink back into this repository. readlink -f
# resolves that, so ../../src/panel lands in the repo rather than
# somewhere under output/.
set -e

TARGET_DIR="$1"

# /data is where /etc/init.d/S03data mounts the persistent partition.
# The mountpoint has to exist in the image: the root filesystem is
# mounted read-only, so the script cannot create it at boot, and every
# mount onto it fails - including the tmpfs fallback that is supposed to
# keep the unit working when the partition is unusable. Buildroot's
# skeleton provides /media and /mnt but not this.
#
# Found the hard way on a real BDP-1: the partition was grown and
# formatted correctly, and then nothing could be mounted on it, so MPD
# and myMPD both failed to start with "No such file or directory".
install -d -m 0755 "$TARGET_DIR/data"

BOARD_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PANEL_SRC="$BOARD_DIR/../../src/panel"

[ -f "$PANEL_SRC/bdp-panel.c" ] || {
	echo "post-build: no panel source at $PANEL_SRC, skipping"; exit 0; }

# Glob the tuple rather than hardcoding it, so changing the libc or the
# architecture does not silently leave this pointing at a compiler that
# is no longer there.
CROSS_GCC="$(ls "${HOST_DIR}"/bin/*-linux-gcc 2>/dev/null | head -1)"
[ -n "$CROSS_GCC" ] || { echo "post-build: no cross gcc in ${HOST_DIR}/bin"; exit 1; }

# Clean either side, so src/panel never keeps a binary whose
# architecture depends on whoever ran make there last.
make -C "$PANEL_SRC" clean >/dev/null
# MPD=1 rather than letting it autodetect: the panel daemon's whole job
# in the image is to follow MPD, and a build that quietly decided it
# could not find libmpdclient would produce a binary that comes up, holds
# the handshake, and does nothing else.
make -C "$PANEL_SRC" CROSS_COMPILE="${CROSS_GCC%gcc}" MPD=1
install -D -m 0755 "$PANEL_SRC/bdp-panel" "$TARGET_DIR/usr/bin/bdp-panel"
make -C "$PANEL_SRC" clean >/dev/null
echo "post-build: installed /usr/bin/bdp-panel"

# Append our USB automount rule to Buildroot's mdev.conf rather than
# shipping a fork of the whole file in the overlay. mdev has no include
# directive, and Buildroot's version carries the device permissions for
# tty, sound and input that we have no reason to own.
#
# Order matters - mdev stops at the first matching rule - but appending
# is safe here: nothing above matches a block device. The guard is
# because TARGET_DIR survives between builds and this script runs on
# every one.
MDEV_RULES="$BOARD_DIR/mdev-usb.conf"
if [ -f "$MDEV_RULES" ] && [ -f "$TARGET_DIR/etc/mdev.conf" ]; then
	if ! grep -q 'slmp-usb-mount' "$TARGET_DIR/etc/mdev.conf"; then
		cat "$MDEV_RULES" >> "$TARGET_DIR/etc/mdev.conf"
		echo "post-build: added USB automount rule to /etc/mdev.conf"
	fi
fi
