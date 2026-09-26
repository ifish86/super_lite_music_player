#!/usr/bin/env bash
#
# phase 1.sh - Phase 1 firmware image for super_lite_music_player.
#
# Target: AMD Geode LX, 256MB RAM, 4GB CompactFlash, ESI Juli@.
#
# Produces a bootable MBR disk image containing:
#   - Linux 6.6 LTS built for -march=geode (no NOPL emitted)
#   - BusyBox userland, BusyBox init, mdev
#   - MPD with ALSA output
#   - syslinux, installed from the host's own syslinux package so the
#     boot sector, ldlinux.sys and ldlinux.c32 are all one version
#
# Not included yet: myMPD, the panel daemon, runit, A/B slots. Those
# arrive as a BR2_EXTERNAL tree once the base boots and plays audio.
#
# Run on a modern x86_64 host. Never on the target.
#
# Env overrides: BUILDROOT_VERSION KERNEL_VERSION WORKDIR JOBS
#                SLMP_YES=1                 answer prompts with yes
#                SLMP_ALLOW_UNBOOTABLE=1    build without host syslinux

set -euo pipefail

# ---------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------

# Buildroot LTS releases are the .02 of each year.
# Check https://buildroot.org/download.html before bumping.
BUILDROOT_VERSION="${BUILDROOT_VERSION:-2025.02.9}"

# Pinned to 6.6 LTS deliberately. x86-32 support is being steadily
# pruned upstream and MGEODE_LX is exactly the kind of symbol that
# disappears in a release nobody announces. Verify it still exists
# before bumping this.
#
# Check https://cdn.kernel.org/pub/linux/kernel/v6.x/ for the current
# 6.6.x patch level.
KERNEL_VERSION="${KERNEL_VERSION:-6.6.100}"

BOARD_NAME="slmp"

# Everything Buildroot is handed must be an ABSOLUTE path. Buildroot
# resolves relative paths in .config against its own top directory, not
# against the directory this script was run from, so "./output/..."
# silently becomes "<buildroot>/output/..." and the overlay, the kernel
# fragment and post-image.sh all vanish without a word.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SLMPBUILDDIR="$SCRIPT_DIR/output"
WORKDIR="${WORKDIR:-$SLMPBUILDDIR/slmp-build}"
JOBS="${JOBS:-$(nproc)}"

# Boot partition offset, in bytes. Must match `offset` in genimage.cfg
# below. syslinux needs to be told where the FAT filesystem starts
# inside the disk image.
BOOT_OFFSET=1048576   # 1 MiB

BR_DIR="$WORKDIR/buildroot-$BUILDROOT_VERSION"
BOARD_DIR="$WORKDIR/board/$BOARD_NAME"
OVERLAY_DIR="$BOARD_DIR/rootfs-overlay"
DL_DIR="$WORKDIR/dl"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# Prompts have to survive being run from a pipe or a CI job. `read`
# against a closed stdin returns non-zero, which under `set -e` exits
# with no explanation at all.
confirm() {
    [ "${SLMP_YES:-0}" != "1" ] || return 0
    [ -t 0 ] || die "$1 (not a tty; re-run with SLMP_YES=1 to accept)"
    printf '\n%s [y/N] ' "$1"
    local reply=""
    read -r reply || true
    case "$reply" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------
# Environment checks
# ---------------------------------------------------------------------

log "Checking environment"

[ "$(id -u)" -ne 0 ] || die "Do not run this as root. Buildroot refuses, correctly."

# WSL: version and filesystem checks. Both of these produce failures
# that look like source corruption rather than like what they are.
IS_WSL=0
if grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=1
    case "$(uname -r)" in
        *WSL2*|*wsl2*) ;;
        *) die "This looks like WSL1, which has no real kernel.
Buildroot's fakeroot and device node handling will not work.
From PowerShell:  wsl --set-version <distro> 2" ;;
    esac
fi

# Buildroot refuses to build if PATH contains an empty element, ".", or
# any whitespace, and it makes that check from inside the build rather
# than up front, so you find out after the toolchain has started.
#
# On WSL it is close to guaranteed. With no /etc/wsl.conf, interop's
# appendWindowsPath defaults to true and the entire Windows PATH is
# appended, "/mnt/c/Program Files/..." and all.
#
# Drop the offending entries rather than asking for them to be fixed by
# hand. Nothing in a Buildroot build wants them, and the host tool check
# below runs against the cleaned PATH, so anything genuinely needed is
# still caught here rather than an hour in.
clean_path() {
    local entry out="" dropped=0
    local IFS=:
    for entry in $PATH; do
        case "$entry" in
            "") dropped=$((dropped + 1)); continue ;;
            .|*[[:space:]]*)
                warn "dropping PATH entry: $entry"
                dropped=$((dropped + 1)); continue ;;
        esac
        out="${out:+$out:}$entry"
    done
    # Rebuilding from valid entries alone also removes the leading,
    # trailing and doubled colons that Buildroot reads as "." anyway.
    [ "$out" = "$PATH" ] || dropped=$((dropped + 1))
    PATH="$out"
    export PATH
    return $(( dropped > 0 ))
}

if ! clean_path; then
    warn "PATH was sanitised for this build. To fix it permanently on WSL,"
    warn "put this in /etc/wsl.conf and run 'wsl --shutdown' from PowerShell:"
    warn "    [interop]"
    warn "    appendWindowsPath = false"
fi
[ -n "$PATH" ] || die "PATH is empty after removing unusable entries."

mkdir -p "$WORKDIR" "$DL_DIR"

# Building on a Windows-backed mount is the single biggest time sink
# available on WSL. DrvFs is far slower for many-small-file work, has
# no real ownership semantics, and is case-insensitive.
if command -v findmnt >/dev/null 2>&1; then
    WORKFS="$(findmnt -no FSTYPE -T "$WORKDIR" 2>/dev/null || echo unknown)"
    case "$WORKFS" in
        9p|drvfs|drvfs2|cifs|v9fs)
            die "WORKDIR is on a Windows-backed mount ($WORKFS): $WORKDIR
Buildroot will fail in ways that look like corrupted sources.
Re-run with a native Linux path, for example:
  WORKDIR=\"\$HOME/slmp-build\" '$0'" ;;
    esac
fi

# Buildroot cannot cope with a space anywhere in its own path. Note this
# is checked against the resolved absolute path, because that is what
# ends up in .config and in the make command lines.
case "$WORKDIR" in
    *[[:space:]]*) die "WORKDIR contains whitespace: $WORKDIR
Buildroot cannot cope. Re-run with:
  WORKDIR=\"\$HOME/slmp-build\" '$0'" ;;
esac

MISSING=()
for tool in gcc g++ make patch cpio unzip rsync bc wget file perl python3 \
            findmnt dd tar xzcat gzip sed awk; do
    command -v "$tool" >/dev/null 2>&1 || MISSING+=("$tool")
done
if [ ${#MISSING[@]} -gt 0 ]; then
    die "Missing host tools: ${MISSING[*]}
  sudo apt install build-essential patch cpio unzip rsync bc wget file \\
                   perl python3 util-linux xz-utils"
fi

# --- syslinux -------------------------------------------------------
#
# All three pieces must come from the same syslinux version. The host
# installer writes ldlinux.sys into the FAT filesystem and ldlinux.sys
# refuses to load a .c32 module from a different build, so mixing
# Buildroot's syslinux 6.03 with Debian's 6.04-pre gives a working build
# and an image that stops at the syslinux prompt.
#
# Buildroot's BR2_TARGET_SYSLINUX is therefore not used at all: it
# installs nothing into the target filesystem (only into HOST_DIR and
# images/), it deletes the one host binary we would want because that
# binary is cross-compiled for the target, and it drags target
# util-linux + libuuid into the rootfs for nothing. Phase 4 needs a
# target-side syslinux binary to set `--once`; that is a BR2_EXTERNAL
# package, not this.
find_first() {
    local f
    for f in "$@"; do
        [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}

SYSLINUX_MBR="$(find_first \
    /usr/lib/syslinux/mbr/mbr.bin \
    /usr/lib/syslinux/mbr.bin \
    /usr/share/syslinux/mbr.bin || true)"
SYSLINUX_C32="$(find_first \
    /usr/lib/syslinux/modules/bios/ldlinux.c32 \
    /usr/share/syslinux/ldlinux.c32 || true)"
SYSLINUX_BIN="$(command -v syslinux || true)"

if [ -z "$SYSLINUX_BIN" ] || [ -z "$SYSLINUX_MBR" ] || [ -z "$SYSLINUX_C32" ]; then
    warn "Host syslinux is incomplete:"
    warn "  installer:   ${SYSLINUX_BIN:-NOT FOUND}"
    warn "  mbr.bin:     ${SYSLINUX_MBR:-NOT FOUND}"
    warn "  ldlinux.c32: ${SYSLINUX_C32:-NOT FOUND}"
    warn "  sudo apt install syslinux syslinux-common"
    if [ "${SLMP_ALLOW_UNBOOTABLE:-0}" = "1" ]; then
        warn "SLMP_ALLOW_UNBOOTABLE=1: continuing. The image will NOT boot."
        SYSLINUX_BIN=""; SYSLINUX_MBR=""; SYSLINUX_C32=""
    else
        die "Install syslinux, or set SLMP_ALLOW_UNBOOTABLE=1 to build an
unbootable image anyway. Failing now rather than in 90 minutes."
    fi
else
    log "Host syslinux:"
    printf '  installer:   %s\n  mbr.bin:     %s\n  ldlinux.c32: %s\n' \
        "$SYSLINUX_BIN" "$SYSLINUX_MBR" "$SYSLINUX_C32"
fi

# Guard the rm -rf further down against a half-initialised environment.
case "$OVERLAY_DIR" in
    /*/board/"$BOARD_NAME"/rootfs-overlay) : ;;
    *) die "OVERLAY_DIR looks wrong, refusing to rm -rf it: '$OVERLAY_DIR'" ;;
esac

mkdir -p "$BOARD_DIR"

# ---------------------------------------------------------------------
# Fetch Buildroot
# ---------------------------------------------------------------------

if [ ! -d "$BR_DIR" ]; then
    log "Fetching Buildroot $BUILDROOT_VERSION"
    TARBALL="$DL_DIR/buildroot-$BUILDROOT_VERSION.tar.gz"
    [ -f "$TARBALL" ] || \
        wget -O "$TARBALL" \
        "https://buildroot.org/downloads/buildroot-$BUILDROOT_VERSION.tar.gz"
    tar -xzf "$TARBALL" -C "$WORKDIR"
else
    log "Buildroot $BUILDROOT_VERSION already unpacked"
fi

# Confirm the pinned kernel actually exists before committing to it.
log "Checking kernel $KERNEL_VERSION exists upstream"
KURL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL_VERSION.tar.xz"
if ! wget -q --spider "$KURL"; then
    die "linux-$KERNEL_VERSION.tar.xz not found upstream.
Pick a current 6.6.x from https://cdn.kernel.org/pub/linux/kernel/v6.x/
then:  KERNEL_VERSION=6.6.<n> '$0'"
fi

# Buildroot cannot know the version of a custom kernel at kconfig time,
# so BR2_LINUX_KERNEL_CUSTOM_VERSION selects no
# BR2_TOOLCHAIN_HEADERS_AT_LEAST_*. The "Custom kernel headers series"
# choice then falls back to its default, which is REALLY_OLD, i.e. 2.6.
# BR2_KERNEL_HEADERS_AS_KERNEL meanwhile installs the 6.6 headers, and
# linux-headers' own strict check kills the build after the toolchain
# has been made:
#
#   Incorrect selection of kernel headers: expected 2.6.x, got 6.6.x
#
# Declaring the series alongside the pinned version is what every stock
# defconfig with a custom kernel does. Derive it from KERNEL_VERSION so
# that bumping the kernel cannot leave the two disagreeing.
KERNEL_SERIES="$(printf '%s\n' "$KERNEL_VERSION" | cut -d. -f1,2)"
HEADERS_SYMBOL="BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_${KERNEL_SERIES//./_}"

grep -qE "^[[:space:]]*config ${HEADERS_SYMBOL}$" \
    "$BR_DIR/package/linux-headers/Config.in.host" || \
    die "Buildroot $BUILDROOT_VERSION has no $HEADERS_SYMBOL.
Kernel $KERNEL_VERSION is outside the header series this Buildroot knows
about. Available:
$(grep -oE 'BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_[0-9_]+' \
    "$BR_DIR/package/linux-headers/Config.in.host" | sort -uV | sed 's/^/  /')"

# ---------------------------------------------------------------------
# Kernel configuration fragment
# ---------------------------------------------------------------------
#
# Disabled symbols use the canonical "is not set" form. CONFIG_FOO=n is
# not how kconfig writes a disabled symbol and merge_config's handling
# of it is not something to rely on.
#
# Only symbols that are actually user-settable belong here. A symbol
# with no prompt (SND_PCM, VGA_CONSOLE on x86) cannot be set from a
# fragment at all; it is either selected by something else or it isn't.

log "Writing kernel fragment"

cat > "$BOARD_DIR/linux.fragment" <<'EOF'
# --- CPU ---------------------------------------------------------------
# The single most important line in this file. Anything else emits NOPL
# and the board dies with an illegal instruction during early boot.
CONFIG_MGEODE_LX=y
CONFIG_X86_32=y
# 256MB of RAM, so no highmem. NOHIGHMEM is the choice member that has
# to be turned ON: "# CONFIG_HIGHMEM4G is not set" on its own just lets
# kconfig fall back to the choice default, which is HIGHMEM4G again.
CONFIG_NOHIGHMEM=y
# CONFIG_SMP is not set
# Legacy BIOS only. i386_defconfig turns EFI and the EFI stub on.
# CONFIG_EFI is not set

# --- Storage -----------------------------------------------------------
# CF card is on the CS5536 PATA channel in True IDE mode.
CONFIG_ATA=y
CONFIG_ATA_SFF=y
CONFIG_ATA_BMDMA=y
CONFIG_PATA_CS5536=y
CONFIG_PATA_AMD=y
CONFIG_BLK_DEV_SD=y
CONFIG_EXT4_FS=y
CONFIG_VFAT_FS=y
CONFIG_NLS_CODEPAGE_437=y
CONFIG_NLS_ISO8859_1=y
CONFIG_TMPFS=y

# --- Audio -------------------------------------------------------------
CONFIG_SOUND=y
CONFIG_SND=y
CONFIG_SND_PCI=y
# ESI Juli@ (Envy24HT / ICE1724). The Juli@-specific quirk code lives
# inside this driver.
CONFIG_SND_ICE1724=y
# USB DAC path.
CONFIG_SND_USB=y
CONFIG_SND_USB_AUDIO=y
# i386_defconfig enables HD-audio. Nothing here has an HDA codec, but
# whichever driver registers first takes card index 0 and mpd.conf names
# the card by index. Remove the possibility.
# CONFIG_SND_HDA_INTEL is not set

# --- USB ---------------------------------------------------------------
CONFIG_USB=y
CONFIG_USB_EHCI_HCD=y
CONFIG_USB_OHCI_HCD=y
CONFIG_USB_STORAGE=y
# The CS5536 has OHCI and EHCI. Nothing else.
# CONFIG_USB_XHCI_HCD is not set
# CONFIG_USB_UHCI_HCD is not set

# --- Serial ------------------------------------------------------------
# The front panel link. There is deliberately no getty on it.
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_SERIAL_8250_NR_UARTS=4
CONFIG_SERIAL_8250_RUNTIME_UARTS=4

# --- Watchdog ----------------------------------------------------------
# CS5536 hardware watchdog. The panel daemon pets this from its main
# loop once it exists.
#
# GEODE_WDT depends on CS5535_MFGPT, which depends on MFD_CS5535. Set
# CONFIG_GEODE_WDT on its own and kconfig drops it without a word, and
# the first sign of trouble is a Phase 3 panel daemon opening
# /dev/watchdog and getting ENOENT.
CONFIG_WATCHDOG=y
CONFIG_MFD_CS5535=y
CONFIG_CS5535_MFGPT=y
CONFIG_GEODE_WDT=y

# --- Geode crypto ------------------------------------------------------
# The LX has a dedicated AES block. Not AES-NI, but far better than
# software AES on a 500MHz core.
CONFIG_CRYPTO=y
CONFIG_CRYPTO_DEV_GEODE=y
CONFIG_HW_RANDOM=y
CONFIG_HW_RANDOM_GEODE=y

# --- Networking --------------------------------------------------------
CONFIG_NET=y
CONFIG_INET=y
CONFIG_PACKET=y
# Shotgun approach until lspci on a real unit says which one it is.
# Trim to the one that matters; every driver here is dead weight.
CONFIG_NET_VENDOR_VIA=y
CONFIG_VIA_RHINE=y
CONFIG_NET_VENDOR_REALTEK=y
CONFIG_8139TOO=y
CONFIG_R8169=y
CONFIG_NET_VENDOR_NATSEMI=y
CONFIG_NATSEMI=y

# --- Trim --------------------------------------------------------------
# No DRM and no fbdev. The VGA text console has no prompt on x86 and
# stays on by default, which is all console=tty0 needs.
# CONFIG_DRM is not set
# CONFIG_FB is not set
# CONFIG_SOUND_OSS_CORE is not set
EOF

# Symbols that must survive into the kernel .config or the image is not
# worth flashing. Checked after the build, because generating the kernel
# .config needs the cross toolchain built first.
KERNEL_CRITICAL=(
    CONFIG_MGEODE_LX=y
    CONFIG_NOHIGHMEM=y
    CONFIG_PATA_CS5536=y
    CONFIG_EXT4_FS=y
    CONFIG_VFAT_FS=y
    CONFIG_SND_ICE1724=y
    CONFIG_GEODE_WDT=y
)

# ---------------------------------------------------------------------
# BusyBox configuration fragment
# ---------------------------------------------------------------------
#
# telnetd is off in Buildroot's stock busybox.config. Three symbols turn
# it on, and STANDALONE is the one that matters twice: without it
# busybox.mk skips installing /etc/init.d/S50telnet entirely, so you get
# the applet and nothing to start it.
#
# The port default is already 23 upstream. It is stated here because the
# shipped config carries 0, which is outside the symbol's declared
# range, and relying on kconfig to quietly correct that is the sort of
# thing that changes between releases.

log "Writing busybox fragment"

cat > "$BOARD_DIR/busybox.fragment" <<'EOF'
CONFIG_TELNETD=y
CONFIG_FEATURE_TELNETD_STANDALONE=y
CONFIG_FEATURE_TELNETD_PORT_DEFAULT=23
EOF

# ---------------------------------------------------------------------
# Root filesystem overlay
# ---------------------------------------------------------------------
#
# Two things about the Buildroot sysv skeleton drive the layout below:
#
#   /var/log -> ../tmp     and     /var/run -> ../run
#
# Both are symlinks. Mounting a tmpfs on /var/log therefore stacks a
# second tmpfs on top of /tmp, and the previous version of this script
# did exactly that, ending up with three tmpfs instances on /tmp and
# whichever one was mounted last holding the files. Mount /tmp and /run
# once, and let /var/log and /var/run follow their symlinks.

log "Writing rootfs overlay"

rm -rf "$OVERLAY_DIR"
mkdir -p "$OVERLAY_DIR"/etc/network \
         "$OVERLAY_DIR"/etc/init.d \
         "$OVERLAY_DIR"/mnt/music \
         "$OVERLAY_DIR"/boot

# Note: /etc/resolv.conf is deliberately NOT touched here. udhcpc would
# not be able to write it on a read-only root, but Buildroot's skeleton
# already ships it as a symlink to ../tmp/resolv.conf and its
# udhcpc.script is written to follow that. Leave it alone.
#
# Note: /etc/dropbear is deliberately NOT touched here. Buildroot's
# dropbear package already symlinks it to /var/run/dropbear, and its
# S50dropbear detects a read-only root and creates the directory the
# symlink points at. Overriding it with a symlink to somewhere else only
# defeats that detection.

# BusyBox init. Phase 1 uses the stock Buildroot S?? scripts; runit
# replaces this whole block in Phase 3.
#
# The getty is on tty1 ONLY. A getty on the panel's UART would spray
# login prompts at the display.
#
# fstab is the single source of truth for mounts, reached via `mount -a`
# rather than by repeating every mount here. mdev is started by
# Buildroot's S10mdev out of rcS, which also registers the hotplug
# helper; calling `mdev -s` here as well would only do half the job.
cat > "$OVERLAY_DIR/etc/inittab" <<'EOF'
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
::sysinit:/bin/mount -t devtmpfs devtmpfs /dev
::sysinit:/bin/mkdir -p /dev/pts /dev/shm
::sysinit:/bin/mount -a
::sysinit:/bin/mkdir -p /run/lock /tmp/mpd/playlists
::sysinit:/bin/hostname -F /etc/hostname
::sysinit:/etc/init.d/rcS

tty1::respawn:/sbin/getty -L tty1 0 vt100

::shutdown:/etc/init.d/rcK
::shutdown:/bin/umount -a -r
::ctrlaltdel:/sbin/reboot
EOF

# Root is partition 2. Partition 1 is the FAT boot partition.
#
# `/` carries noauto so `mount -a` does not trip over a filesystem the
# kernel has already mounted. It is never remounted rw: that is what
# keeps the CF card alive.
cat > "$OVERLAY_DIR/etc/fstab" <<'EOF'
# <file system>  <mount pt>  <type>  <options>                              <dump> <pass>
/dev/sda2        /           ext4    ro,noatime,noauto                       0      1
/dev/sda1        /boot       vfat    ro,noauto                               0      0
proc             /proc       proc    defaults                                0      0
sysfs            /sys        sysfs   defaults                                0      0
devpts           /dev/pts    devpts  defaults,gid=5,mode=620,ptmxmode=0666    0      0
tmpfs            /dev/shm    tmpfs   mode=1777,nosuid,nodev                  0      0
tmpfs            /tmp        tmpfs   mode=1777,nosuid,nodev,size=16m         0      0
tmpfs            /run        tmpfs   mode=0755,nosuid,nodev,size=4m          0      0
# /var/log and /var/run are skeleton symlinks to /tmp and /run. Do not
# give them mounts of their own.
EOF

cat > "$OVERLAY_DIR/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

# Ethernet always falls back to DHCP regardless of stored config.
# One of the three mandatory bootstrap escape hatches.
auto eth0
iface eth0 inet dhcp
EOF

# All writable paths point at tmpfs directly. No symlink games: you
# cannot create a symlink on a read-only rootfs at runtime, and the
# previous version's `|| true` quietly hid that failure.
#
# /tmp/mpd and /tmp/mpd/playlists are created by inittab sysinit. MPD
# creates its own files but not its own directories.
cat > "$OVERLAY_DIR/etc/mpd.conf" <<'EOF'
# Phase 1 MPD config. Deliberately minimal.
# Started by Buildroot's own /etc/init.d/S95mpd.

music_directory     "/mnt/music"
playlist_directory  "/tmp/mpd/playlists"
db_file             "/tmp/mpd/database"
state_file          "/tmp/mpd/state"
pid_file            "/var/run/mpd.pid"

# sticker_file is deliberately absent: it needs BR2_PACKAGE_MPD_SQLITE,
# and the sticker database is a Phase 2 concern that arrives with myMPD.

bind_to_address     "0.0.0.0"
port                "6600"
# /var/log is a symlink to /tmp, so this lands on tmpfs.
log_file            "/var/log/mpd.log"

# The database lives on tmpfs and is rebuilt at every boot. That is
# fine at Phase 1 scale and deliberately unacceptable at 100k tracks,
# which is a Phase 2 problem.

# 256MB of RAM. Do not let the buffer get greedy.
audio_buffer_size   "2048"

# Juli@ S/PDIF. Verify the card index with `aplay -l` on the target.
# hw:0,0 is a guess until a real unit says otherwise; HD-audio is
# compiled out of the kernel so nothing else should claim index 0.
audio_output {
    type        "alsa"
    name        "Julia SPDIF"
    device      "hw:0,0"
    mixer_type  "none"
}

# USB DAC. Left disabled so it does not fight for the default.
#audio_output {
#    type        "alsa"
#    name        "USB DAC"
#    device      "hw:1,0"
#    mixer_type  "none"
#}
EOF

# Buildroot's alsa-utils package ships no init script, so nothing
# restores the mixer at boot and the Juli@ comes up muted. Phase 1 has
# to prove this works, hence S30alsa, ordered before S95mpd.
#
# There is nowhere to *store* state at shutdown on a read-only root, so
# the state file is baked into the image instead. Capture it once on a
# running unit with
#     alsactl -f /etc/asound.state store
# copy it into this overlay, and rebuild.
cat > "$OVERLAY_DIR/etc/init.d/S30alsa" <<'EOF'
#!/bin/sh
# Restore the ALSA mixer state baked into the image.
case "$1" in
    start)
        [ -f /etc/asound.state ] || exit 0
        printf 'Restoring ALSA mixer state: '
        if /usr/sbin/alsactl -f /etc/asound.state restore; then
            echo OK
        else
            echo FAIL
        fi
        ;;
    stop|restart|reload)
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"; exit 1
        ;;
esac
EOF
chmod +x "$OVERLAY_DIR/etc/init.d/S30alsa"

# Front panel link.
#
# S01 is not arbitrary. rcS runs these in sort order, so S01panel goes
# before S01seedrng, S01syslogd and everything after them: the enable
# handshake is what keeps the unit powered on, and every service that
# starts ahead of it is time spent hoping the panel is patient. mpd sits
# at S95 for the opposite reason, it can afford to wait.
#
# /dev/ttyS1 is a static devtmpfs node created by the kernel, so it
# exists well before mdev runs at S10 and this ordering is safe.
#
# Args live in /etc/default/bdp-panel so the port or the version string
# can be changed on the unit without a rebuild.
cat > "$OVERLAY_DIR/etc/init.d/S01panel" <<'EOF'
#!/bin/sh
#
# S01panel - front panel link. Must run first.

DAEMON=/usr/bin/bdp-panel
PIDFILE=/var/run/bdp-panel.pid
LOGFILE=/var/log/bdp-panel.log
BDP_PANEL_ARGS=""

# shellcheck source=/dev/null
[ -r /etc/default/bdp-panel ] && . /etc/default/bdp-panel

start() {
	printf 'Starting front panel: '
	# Wrapped in a shell so the button log can be redirected; exec
	# keeps the pid start-stop-daemon recorded pointing at the daemon
	# rather than at a shell that has already gone.
	start-stop-daemon -S -q -m -b -p "$PIDFILE" \
		-x /bin/sh -- -c "exec $DAEMON $BDP_PANEL_ARGS >>$LOGFILE 2>&1"
	if [ $? = 0 ]; then echo OK; else echo FAIL; fi
}

stop() {
	printf 'Stopping front panel: '
	start-stop-daemon -K -q -p "$PIDFILE"
	if [ $? = 0 ]; then echo OK; else echo FAIL; fi
	rm -f "$PIDFILE"
}

case "$1" in
	start)   start ;;
	stop)    stop ;;
	restart|reload) stop; sleep 1; start ;;
	*)       echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
EOF
chmod +x "$OVERLAY_DIR/etc/init.d/S01panel"

mkdir -p "$OVERLAY_DIR/etc/default"
cat > "$OVERLAY_DIR/etc/default/bdp-panel" <<'EOF'
# Arguments for /usr/bin/bdp-panel, read by /etc/init.d/S01panel.
#
# The defaults compiled into the binary are /dev/ttyS1 and the version
# string "S3.00 2023-04-08", which is the handshake this panel accepts.
# Override here to try a different port or version without rebuilding.
#
#BDP_PANEL_ARGS="-d /dev/ttyS2"
#BDP_PANEL_ARGS="-v 'S3.00 2023-04-08'"
#
# Send an exact byte sequence instead of the built-in one:
#BDP_PANEL_ARGS="-X '1C 53 33 2E 30 30 20 32 30 32 33 2D 30 34 2D 30 38 0A 0D'"
#
# Terminate commands with LF only instead of LF CR:
#BDP_PANEL_ARGS="-L"

BDP_PANEL_ARGS=""
EOF

# No S50mpd here. Buildroot's mpd package installs /etc/init.d/S95mpd,
# and shipping a second start script means mpd is launched twice at
# boot: the first wins, the second prints FAIL, and the boot log lies
# about what happened.

# ---------------------------------------------------------------------
# Disk image layout
# ---------------------------------------------------------------------
#
# Boot partition offset is pinned at 1 MiB so post-image.sh can hand
# syslinux a hardcoded offset rather than parsing it back out.
#
# -F 32 is not optional. mkfs.vfat picks the FAT width from the volume
# size and at 64M it picks FAT16, while partition-type 0xC declares
# FAT32 LBA. Forcing the width is what makes the two agree.

log "Writing genimage config"

cat > "$BOARD_DIR/genimage.cfg" <<'EOF'
image boot.vfat {
  vfat {
    label = "SLMPBOOT"
    extraargs = "-F 32"
    # `files` is an option of the vfat section, not of the image. At
    # image level genimage rejects it: "no such option 'files'".
    files = { "bzImage", "syslinux.cfg", "ldlinux.c32" }
  }
  size = 64M
}

image sdcard.img {
  hdimage {
    partition-table-type = "mbr"
  }

  partition boot {
    partition-type = 0xC
    bootable = "true"
    image = "boot.vfat"
    offset = 1M
  }

  partition rootfs {
    partition-type = 0x83
    image = "rootfs.ext2"
    # Phase 4 splits this into A/B slots plus a config partition.
  }
}
EOF

cat > "$BOARD_DIR/syslinux.cfg" <<'EOF'
DEFAULT slmp
PROMPT 0
TIMEOUT 10

LABEL slmp
  KERNEL /bzImage
  # No console= on ttyS0: that UART belongs to the front panel.
  # Add it only when the panel is physically disconnected.
  APPEND root=/dev/sda2 ro rootwait console=tty0
EOF

# post-build.sh: cross-compiles the panel link and installs it into the
# target filesystem.
#
# This is a post-BUILD script, not post-image: it has to run after the
# toolchain exists but before the rootfs is packed. The toolchain tuple
# is globbed rather than hardcoded so that changing BR2_x86_geode or the
# libc does not silently leave this pointing at a compiler that is no
# longer there.
#
# The source tree is cleaned either side of the build. src/panel is
# otherwise left holding a binary whose architecture depends on whoever
# ran make there last, which is its own small trap.
cat > "$BOARD_DIR/post-build.sh" <<EOF
#!/bin/sh
set -e

TARGET_DIR="\$1"
PANEL_SRC="$SCRIPT_DIR/src/panel"

[ -f "\$PANEL_SRC/bdp-panel.c" ] || {
    echo "post-build: no panel source at \$PANEL_SRC, skipping"; exit 0; }

CROSS_GCC="\$(ls "\${HOST_DIR}"/bin/*-linux-gcc 2>/dev/null | head -1)"
[ -n "\$CROSS_GCC" ] || { echo "post-build: no cross gcc in \${HOST_DIR}/bin"; exit 1; }

make -C "\$PANEL_SRC" clean >/dev/null
make -C "\$PANEL_SRC" CROSS_COMPILE="\${CROSS_GCC%gcc}"
install -D -m 0755 "\$PANEL_SRC/bdp-panel" "\$TARGET_DIR/usr/bin/bdp-panel"
make -C "\$PANEL_SRC" clean >/dev/null
echo "post-build: installed /usr/bin/bdp-panel"
EOF
chmod +x "$BOARD_DIR/post-build.sh"

# post-image.sh: this is where the previous version fell down. genimage
# assembles filesystems, it does not make anything bootable. The MBR
# boot code and ldlinux.sys both have to be written explicitly.
#
# The syslinux paths are resolved once, up front, by the parent script
# and baked in here, so a missing file is an error at minute zero rather
# than at minute ninety.
cat > "$BOARD_DIR/post-image.sh" <<EOF
#!/bin/sh
set -e

BOARD_DIR="\$(dirname "\$0")"
GENIMAGE_CFG="\$BOARD_DIR/genimage.cfg"
GENIMAGE_TMP="\${BUILD_DIR}/genimage.tmp"
IMG="\${BINARIES_DIR}/sdcard.img"
BOOT_OFFSET=$BOOT_OFFSET

# Resolved by phase 1.sh from the host's syslinux install. Empty means
# SLMP_ALLOW_UNBOOTABLE was set.
SYSLINUX_BIN="$SYSLINUX_BIN"
SYSLINUX_MBR="$SYSLINUX_MBR"
SYSLINUX_C32="$SYSLINUX_C32"

cp "\$BOARD_DIR/syslinux.cfg" "\${BINARIES_DIR}/syslinux.cfg"

if [ -n "\$SYSLINUX_C32" ]; then
    cp "\$SYSLINUX_C32" "\${BINARIES_DIR}/ldlinux.c32"
else
    # genimage lists ldlinux.c32 among the FAT contents, so it has to
    # exist even when we cannot make the image bootable.
    : > "\${BINARIES_DIR}/ldlinux.c32"
fi

rm -rf "\$GENIMAGE_TMP"
genimage \\
    --rootpath "\${TARGET_DIR}" \\
    --tmppath "\$GENIMAGE_TMP" \\
    --inputpath "\${BINARIES_DIR}" \\
    --outputpath "\${BINARIES_DIR}" \\
    --config "\$GENIMAGE_CFG"

# --- Make it bootable -------------------------------------------------

if [ -z "\$SYSLINUX_BIN" ]; then
    echo "post-image: WARNING: no host syslinux, image is NOT bootable"
    exit 0
fi

# 1. MBR boot code into the first 440 bytes, leaving the partition
#    table intact.
dd if="\$SYSLINUX_MBR" of="\$IMG" bs=440 count=1 conv=notrunc status=none
echo "post-image: wrote MBR boot code from \$SYSLINUX_MBR"

# 2. ldlinux.sys into the FAT filesystem at the boot partition offset.
#    Same syslinux install as ldlinux.c32 above, which is the whole
#    point of resolving both from the host rather than mixing sources.
"\$SYSLINUX_BIN" --offset "\$BOOT_OFFSET" --install "\$IMG"
echo "post-image: installed syslinux at offset \$BOOT_OFFSET"
EOF
chmod +x "$BOARD_DIR/post-image.sh"

# ---------------------------------------------------------------------
# Buildroot defconfig
# ---------------------------------------------------------------------

log "Writing defconfig"

DEFCONFIG="$BR_DIR/configs/${BOARD_NAME}_defconfig"

cat > "$DEFCONFIG" <<EOF
# --- Target architecture ----------------------------------------------
BR2_i386=y
BR2_x86_geode=y

# --- Toolchain ---------------------------------------------------------
# musl for size. MPD is C++17 so C++ support is not optional.
# GCC version deliberately left at Buildroot's default.
BR2_TOOLCHAIN_BUILDROOT_MUSL=y
BR2_TOOLCHAIN_BUILDROOT_CXX=y

# --- Downloads ---------------------------------------------------------
# Outside the buildroot tree, so deleting and re-extracting Buildroot
# does not mean re-downloading a gigabyte of tarballs.
BR2_DL_DIR="$DL_DIR"

# --- System ------------------------------------------------------------
BR2_TARGET_GENERIC_HOSTNAME="$BOARD_NAME"
BR2_TARGET_GENERIC_ISSUE="super_lite_music_player"
BR2_INIT_BUSYBOX=y
# devtmpfs alone gives no hotplug helper and no /etc/mdev.conf. mdev is
# what the proposal commits to, and its firmware loader is what Phase 3
# needs for USB WiFi blobs.
BR2_ROOTFS_DEVICE_CREATION_DYNAMIC_MDEV=y
BR2_TARGET_GENERIC_GETTY_PORT="tty1"
BR2_TARGET_GENERIC_ROOT_PASSWD="$BOARD_NAME"
BR2_ROOTFS_OVERLAY="$OVERLAY_DIR"
BR2_ROOTFS_POST_BUILD_SCRIPT="$BOARD_DIR/post-build.sh"
BR2_ROOTFS_POST_IMAGE_SCRIPT="$BOARD_DIR/post-image.sh"
# telnetd on port 23. Plaintext, so this is a wired-LAN bench
# convenience, not a way in from anywhere untrusted.
BR2_PACKAGE_BUSYBOX_CONFIG_FRAGMENT_FILES="$BOARD_DIR/busybox.fragment"
# Network config comes from the overlay, not from BR2_SYSTEM_DHCP.

# --- Kernel ------------------------------------------------------------
BR2_LINUX_KERNEL=y
BR2_LINUX_KERNEL_CUSTOM_VERSION=y
BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="$KERNEL_VERSION"
BR2_LINUX_KERNEL_DEFCONFIG="i386"
BR2_LINUX_KERNEL_USE_DEFCONFIG=y
BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="$BOARD_DIR/linux.fragment"
BR2_LINUX_KERNEL_BZIMAGE=y
# Headers come from the kernel being built, and the series has to be
# stated separately because a custom version tells kconfig nothing.
BR2_KERNEL_HEADERS_AS_KERNEL=y
$HEADERS_SYMBOL=y

# --- Filesystem --------------------------------------------------------
BR2_TARGET_ROOTFS_EXT2=y
BR2_TARGET_ROOTFS_EXT2_4=y
BR2_TARGET_ROOTFS_EXT2_SIZE="400M"
BR2_TARGET_ROOTFS_TAR=y

# --- Bootloader --------------------------------------------------------
# No BR2_TARGET_SYSLINUX. It installs nothing into the target, Buildroot
# deletes the one host binary it builds because that binary is
# cross-compiled, and it pulls target util-linux + libuuid into the
# rootfs for nothing. The boot bits come from the host's own syslinux
# package so that ldlinux.sys and ldlinux.c32 are the same version.
# Phase 4's on-device "syslinux --once" writer is a BR2_EXTERNAL
# package, not this symbol.

# --- Audio -------------------------------------------------------------
BR2_PACKAGE_ALSA_UTILS=y
BR2_PACKAGE_ALSA_UTILS_ALSACTL=y
BR2_PACKAGE_ALSA_UTILS_AMIXER=y
BR2_PACKAGE_ALSA_UTILS_APLAY=y

BR2_PACKAGE_MPD=y
BR2_PACKAGE_MPD_ALSA=y
BR2_PACKAGE_MPD_FLAC=y
BR2_PACKAGE_MPD_VORBIS=y
BR2_PACKAGE_MPD_MPG123=y
BR2_PACKAGE_MPD_WAVPACK=y
BR2_PACKAGE_MPD_CURL=y

# --- Diagnostics -------------------------------------------------------
BR2_PACKAGE_PCIUTILS=y
BR2_PACKAGE_DROPBEAR=y
BR2_PACKAGE_STRACE=y
# mpc, for poking at mpd from the console without a web UI. Note the
# name: BR2_PACKAGE_MPC is GNU MPC, the multiprecision complex library
# that GCC builds against, and selecting it would drag GMP and MPFR into
# the image for nothing. The MPD client is BR2_PACKAGE_MPD_MPC.
#
# It selects libmpdclient, which Phase 3's panel daemon needs anyway.
BR2_PACKAGE_MPD_MPC=y
# No BR2_PACKAGE_USBUTILS: it depends on BR2_PACKAGE_HAS_UDEV because
# lsusb wants udev's hwdb, and this image uses mdev. BusyBox's own lsusb
# applet is enabled by default and lists bus/device IDs, which is all
# Phase 1 needs. Revisit only if a device name database becomes worth
# dragging eudev in for.

# --- Host tools --------------------------------------------------------
BR2_PACKAGE_HOST_GENIMAGE=y
BR2_PACKAGE_HOST_DOSFSTOOLS=y
BR2_PACKAGE_HOST_MTOOLS=y
EOF

# ---------------------------------------------------------------------
# Apply and validate
# ---------------------------------------------------------------------
#
# Buildroot silently drops defconfig symbols it does not recognise, and
# quietly changes the value of ones whose dependencies disagree with
# what was asked for. On an unusual target that is how you end up
# debugging an image that was never built the way you thought it was.
#
# Checking that the symbol NAME appears is not enough. BR2_TARGET_SYSLINUX
# _LEGACY_BIOS has no prompt and cannot be set from a defconfig at all,
# but something else selects it, so a name-only check reported success
# while the requested boot flavour had silently become isolinux.

log "Applying defconfig"
make -C "$BR_DIR" "${BOARD_NAME}_defconfig"

check_config() {
    # $1 = label, $2 = .config to inspect, $3.. = requested "SYM=value"
    local label="$1" cfg="$2" bad=0 want sym got
    shift 2
    for want in "$@"; do
        sym="${want%%=*}"
        if grep -qxF "$want" "$cfg"; then
            continue
        fi
        got="$(grep -m1 -E "^${sym}=" "$cfg" || true)"
        if [ -n "$got" ]; then
            warn "$label: $sym is ${got#*=}, asked for ${want#*=}"
        else
            warn "$label: $sym dropped or renamed (wanted ${want#*=})"
        fi
        bad=$((bad + 1))
    done
    return "$bad"
}

log "Validating that requested symbols survived"

REQUESTED=()
while IFS= read -r line; do
    case "$line" in ""|"#"*) continue ;; esac
    REQUESTED+=("$line")
done < "$DEFCONFIG"

DROPPED=0
check_config "defconfig" "$BR_DIR/.config" "${REQUESTED[@]}" || DROPPED=$?

if [ "$DROPPED" -gt 0 ]; then
    warn "$DROPPED symbol(s) did not survive."
    warn "Inspect with:  make -C '$BR_DIR' menuconfig"
    warn "Package names drift between releases. Most likely movers:"
    warn "the MPD codec options and BR2_x86_geode."
    confirm "Continue anyway?" || die "Stopping so you can fix the defconfig."
fi

# Belt and braces: confirm the one setting that matters most actually
# landed in the generated config.
grep -qxF "BR2_x86_geode=y" "$BR_DIR/.config" || \
    die "BR2_x86_geode did not survive. Without it the toolchain will
emit NOPL and nothing will boot. Fix this before building."

# ---------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------

log "Building with $JOBS jobs. First build takes 30-90 minutes."
if [ "$IS_WSL" -eq 1 ]; then
    warn "WSL2 defaults to half the host's RAM. If this OOMs, set"
    warn "memory= in C:\\Users\\<you>\\.wslconfig then: wsl --shutdown"
fi

make -C "$BR_DIR" -j"$JOBS"

# ---------------------------------------------------------------------
# Validate the kernel config
# ---------------------------------------------------------------------
#
# The fragment gets no validation from Buildroot either, and a kernel
# symbol whose dependencies are not met is dropped in silence. This runs
# after the build because generating the kernel .config needs the cross
# toolchain, which is most of the build.

log "Validating kernel config"

KCONFIG="$BR_DIR/output/build/linux-$KERNEL_VERSION/.config"
if [ ! -f "$KCONFIG" ]; then
    warn "kernel .config not found at $KCONFIG, skipping check"
else
    KBAD=0
    check_config "kernel" "$KCONFIG" "${KERNEL_CRITICAL[@]}" || KBAD=$?
    [ "$KBAD" -eq 0 ] || die "$KBAD critical kernel symbol(s) missing. This image
would boot into something that cannot read its own root filesystem, play
audio, or pet the watchdog. Check dependencies in linux.fragment."

    # Everything else in the fragment, as a warning only.
    KWARN=0
    KWANT=()
    while IFS= read -r line; do
        case "$line" in ""|"#"*) continue ;; esac
        KWANT+=("$line")
    done < "$BOARD_DIR/linux.fragment"
    check_config "kernel" "$KCONFIG" "${KWANT[@]}" || KWARN=$?
    [ "$KWARN" -eq 0 ] || warn "$KWARN non-critical kernel symbol(s) differ."
fi

# Same treatment for busybox: applets get dropped silently too.
BBCONFIG="$(find_first "$BR_DIR"/output/build/busybox-*/.config || true)"
if [ -z "$BBCONFIG" ]; then
    warn "busybox .config not found, skipping check"
else
    BBWANT=()
    while IFS= read -r line; do
        case "$line" in ""|"#"*) continue ;; esac
        BBWANT+=("$line")
    done < "$BOARD_DIR/busybox.fragment"
    BBBAD=0
    check_config "busybox" "$BBCONFIG" "${BBWANT[@]}" || BBBAD=$?
    [ "$BBBAD" -eq 0 ] || warn "$BBBAD busybox symbol(s) did not survive."
fi

# Cheap sanity check on the whole point of the exercise. -march=geode
# must not emit NOPL, and nothing in the image may use SSE.
OBJDUMP="$(find_first "$BR_DIR"/output/host/bin/i*-linux-objdump || true)"
if [ -n "$OBJDUMP" ]; then
    log "Checking target binaries for NOPL"
    for b in bin/busybox usr/bin/mpd; do
        [ -f "$BR_DIR/output/target/$b" ] || { warn "$b not found"; continue; }
        dis="$("$OBJDUMP" -d "$BR_DIR/output/target/$b" 2>/dev/null)"
        n="$(printf '%s\n' "$dis" | grep -c '\<nopl\>' || true)"
        tot="$(printf '%s\n' "$dis" | grep -cE '^[[:space:]]+[0-9a-f]+:' || true)"
        if [ "$n" -eq 0 ]; then
            printf '  %-16s %s instructions, no nopl\n' "$b" "$tot"
        else
            warn "$b contains $n nopl instruction(s) out of $tot"
        fi
    done
fi

# ---------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------

IMAGE="$BR_DIR/output/images/sdcard.img"
[ -f "$IMAGE" ] || die "Build finished but $IMAGE is missing. Check output/images/."

log "Done"
printf '  image:  %s\n' "$IMAGE"
# Apparent size is what gets written to the card. du's default reports
# allocated blocks, and the image is sparse, so the two differ wildly.
printf '  size:   %s to write (%s allocated, the file is sparse)\n' \
    "$(du -h --apparent-size "$IMAGE" | cut -f1)" \
    "$(du -h "$IMAGE" | cut -f1)"
[ -n "$SYSLINUX_BIN" ] || warn "This image has no bootloader installed."

if [ "$IS_WSL" -eq 1 ]; then
    cat <<EOF

WSL2 cannot see USB card readers as block devices, so dd will not work
here. Copy the image out and flash from Windows:

    cp "$IMAGE" /mnt/c/Users/\$USER/Downloads/

Then use balenaEtcher, Rufus (DD mode) or Win32DiskImager.

Alternatively, attach the reader into WSL with usbipd-win if you expect
to be reflashing often.
EOF
else
    cat <<EOF

Write to a CF card with:
    sudo dd if=$IMAGE of=/dev/sdX bs=4M status=progress conv=fsync

Confirm /dev/sdX is the card and not your disk before running that.
EOF
fi

cat <<'EOF'

First boot checklist on the target (login root / slmp):

    cat /proc/cpuinfo     flags should show cmov mmx mmxext 3dnow
                          and no sse of any kind
    dmesg | grep -i geode confirm geodewdt and geode-aes loaded
    ls /dev/watchdog      the CS5536 watchdog Phase 3 depends on
    lspci                 identify the real ethernet chip, then trim
                          linux.fragment down to just that driver
    lsusb                 busybox applet; IDs only, no name database
    aplay -l              confirm the Juli@ card index, fix mpd.conf
    alsactl -f /etc/asound.state store
                          then copy that file into the overlay so the
                          mixer comes back after a reboot
    cat /etc/resolv.conf  skeleton symlink into /tmp; should have
                          nameservers in it after DHCP
    mount                 one tmpfs each on /tmp and /run, root ro
    mpc status            or: telnet localhost 6600

EOF
