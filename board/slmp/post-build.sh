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
make -C "$PANEL_SRC" CROSS_COMPILE="${CROSS_GCC%gcc}"
install -D -m 0755 "$PANEL_SRC/bdp-panel" "$TARGET_DIR/usr/bin/bdp-panel"
make -C "$PANEL_SRC" clean >/dev/null
echo "post-build: installed /usr/bin/bdp-panel"
