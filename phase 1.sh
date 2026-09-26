#!/usr/bin/env bash
#
# build-slmp.sh - Phase 1 firmware image for super_lite_music_player.
#
# Target: AMD Geode LX, 256MB RAM, 4GB CompactFlash, ESI Juli@.
#
# Produces a bootable MBR disk image containing:
#   - Linux 6.6 LTS built for -march=geode (no NOPL emitted)
#   - BusyBox userland, BusyBox init
#   - MPD with ALSA output
#   - syslinux, actually installed this time
#
# Not included yet: myMPD, the panel daemon, runit, A/B slots. Those
# arrive as a BR2_EXTERNAL tree once the base boots and plays audio.
#
# Run on a modern x86_64 host. Never on the target.

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
SLMPBUILDDIR="./output"
WORKDIR="${WORKDIR:-$SLMPBUILDDIR/slmp-build}"
JOBS="${JOBS:-$(nproc)}"
BOARD_NAME="slmp"

# Boot partition offset, in bytes. Must match `offset` in genimage.cfg
# below. syslinux needs to be told where the FAT filesystem starts
# inside the disk image.
BOOT_OFFSET=1048576   # 1 MiB

BR_DIR="$WORKDIR/buildroot-$BUILDROOT_VERSION"
BOARD_DIR="$WORKDIR/board/$BOARD_NAME"
OVERLAY_DIR="$BOARD_DIR/rootfs-overlay"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

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

mkdir -p "$WORKDIR"

# Building on a Windows-backed mount is the single biggest time sink
# available on WSL. DrvFs is far slower for many-small-file work, has
# no real ownership semantics, and is case-insensitive.
if command -v findmnt >/dev/null 2>&1; then
    WORKFS="$(findmnt -no FSTYPE -T "$WORKDIR" 2>/dev/null || echo unknown)"
    case "$WORKFS" in
        9p|drvfs|drvfs2|cifs|v9fs)
            die "WORKDIR is on a Windows-backed mount ($WORKFS): $WORKDIR
Buildroot will fail in ways that look like corrupted sources.
Use a native Linux path:  WORKDIR=\$SLMPBUILDDIR/slmp-build $0" ;;
    esac
fi

case "$WORKDIR" in
    *" "*) die "WORKDIR contains a space. Buildroot cannot cope." ;;
esac

MISSING=()
for tool in gcc g++ make patch cpio unzip rsync bc wget file perl python3 findmnt dd; do
    command -v "$tool" >/dev/null 2>&1 || MISSING+=("$tool")
done
if [ ${#MISSING[@]} -gt 0 ]; then
    die "Missing host tools: ${MISSING[*]}
  sudo apt install build-essential patch cpio unzip rsync bc wget file perl python3 util-linux"
fi

# The syslinux *installer* is a host tool and is not reliably provided
# by Buildroot's target syslinux package. Check now rather than 90
# minutes from now.
if ! command -v syslinux >/dev/null 2>&1; then
    warn "Host 'syslinux' installer not found on PATH."
    warn "The build will complete but the image will not be bootable."
    warn "  sudo apt install syslinux syslinux-common"
    printf '\nContinue anyway? [y/N] '
    read -r reply
    case "$reply" in [yY]*) ;; *) die "Stopping." ;; esac
fi

mkdir -p "$BOARD_DIR" "$OVERLAY_DIR"

# ---------------------------------------------------------------------
# Fetch Buildroot
# ---------------------------------------------------------------------

if [ ! -d "$BR_DIR" ]; then
    log "Fetching Buildroot $BUILDROOT_VERSION"
    TARBALL="$WORKDIR/buildroot-$BUILDROOT_VERSION.tar.gz"
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
then:  KERNEL_VERSION=6.6.<n> $0"
fi

# ---------------------------------------------------------------------
# Kernel configuration fragment
# ---------------------------------------------------------------------
#
# Disabled symbols use the canonical "is not set" form. CONFIG_FOO=n is
# not how kconfig writes a disabled symbol and merge_config's handling
# of it is not something to rely on.

log "Writing kernel fragment"

cat > "$BOARD_DIR/linux.fragment" <<'EOF'
# --- CPU ---------------------------------------------------------------
# The single most important line in this file. Anything else emits NOPL
# and the board dies with an illegal instruction during early boot.
CONFIG_MGEODE_LX=y
CONFIG_X86_32=y
# CONFIG_HIGHMEM4G is not set
# CONFIG_SMP is not set

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

# --- Audio -------------------------------------------------------------
CONFIG_SOUND=y
CONFIG_SND=y
CONFIG_SND_PCM=y
CONFIG_SND_PCI=y
# ESI Juli@ (Envy24HT / ICE1724). The Juli@-specific quirk code lives
# inside this driver.
CONFIG_SND_ICE1724=y
# USB DAC path.
CONFIG_SND_USB=y
CONFIG_SND_USB_AUDIO=y

# --- USB ---------------------------------------------------------------
CONFIG_USB=y
CONFIG_USB_EHCI_HCD=y
CONFIG_USB_OHCI_HCD=y
CONFIG_USB_STORAGE=y

# --- Serial ------------------------------------------------------------
# The front panel link. There is deliberately no getty on it.
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_SERIAL_8250_NR_UARTS=4

# --- Watchdog ----------------------------------------------------------
# CS5536 hardware watchdog. The panel daemon pets this from its main
# loop once it exists.
CONFIG_WATCHDOG=y
CONFIG_GEODE_WDT=y

# --- Geode crypto ------------------------------------------------------
# The LX has a dedicated AES block. Not AES-NI, but far better than
# software AES on a 500MHz core.
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
# CONFIG_DRM is not set
# CONFIG_FB is not set
# CONFIG_SOUND_OSS_CORE is not set
EOF

# ---------------------------------------------------------------------
# Root filesystem overlay
# ---------------------------------------------------------------------

log "Writing rootfs overlay"

rm -rf "$OVERLAY_DIR"
mkdir -p "$OVERLAY_DIR"/etc/network \
         "$OVERLAY_DIR"/etc/init.d \
         "$OVERLAY_DIR"/mnt/music \
         "$OVERLAY_DIR"/boot

# Dropbear generates host keys into /etc/dropbear at first start. On a
# read-only root that simply fails and sshd never comes up, which on a
# headless Phase 1 image means no way in at all. Redirect to tmpfs.
ln -sfn /tmp/dropbear "$OVERLAY_DIR/etc/dropbear"

# BusyBox init. Phase 1 uses respawn directly; runit replaces this
# whole block in Phase 3.
#
# The getty is on tty1 ONLY. A getty on the panel's UART would spray
# login prompts at the display.
cat > "$OVERLAY_DIR/etc/inittab" <<'EOF'
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
::sysinit:/bin/mount -t devtmpfs devtmpfs /dev
::sysinit:/bin/mount -t tmpfs -o size=16m tmpfs /tmp
::sysinit:/bin/mount -t tmpfs -o size=8m tmpfs /var/log
::sysinit:/bin/mount -t tmpfs -o size=4m tmpfs /var/run
::sysinit:/bin/mkdir -p /dev/pts /dev/shm
::sysinit:/bin/mount -t devpts devpts /dev/pts
::sysinit:/bin/mkdir -p /tmp/dropbear /tmp/mpd/playlists
::sysinit:/sbin/mdev -s
::sysinit:/etc/init.d/rcS

tty1::respawn:/sbin/getty -L tty1 115200 vt100

::shutdown:/etc/init.d/rcK
::shutdown:/bin/umount -a -r
::ctrlaltdel:/sbin/reboot
EOF

# Root is partition 2. Partition 1 is the FAT boot partition.
cat > "$OVERLAY_DIR/etc/fstab" <<'EOF'
# Root is read-only. Everything that writes goes to tmpfs.
# This is what keeps the CF card alive.
/dev/sda2   /        ext4    ro,noatime  0 1
/dev/sda1   /boot    vfat    ro,noauto   0 0
proc        /proc    proc    defaults    0 0
sysfs       /sys     sysfs   defaults    0 0
tmpfs       /tmp     tmpfs   size=16m    0 0
tmpfs       /var/log tmpfs   size=8m     0 0
tmpfs       /var/run tmpfs   size=4m     0 0
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
cat > "$OVERLAY_DIR/etc/mpd.conf" <<'EOF'
# Phase 1 MPD config. Deliberately minimal.

music_directory     "/mnt/music"
playlist_directory  "/tmp/mpd/playlists"
db_file             "/tmp/mpd/database"
state_file          "/tmp/mpd/state"
sticker_file        "/tmp/mpd/sticker.sql"
pid_file            "/var/run/mpd.pid"

bind_to_address     "0.0.0.0"
port                "6600"
log_file            "/var/log/mpd.log"

# The database lives on tmpfs and is rebuilt at every boot. That is
# fine at Phase 1 scale and deliberately unacceptable at 100k tracks,
# which is a Phase 2 problem.

# 256MB of RAM. Do not let the buffer get greedy.
audio_buffer_size   "2048"

# Juli@ S/PDIF. Verify the card index with `aplay -l` on the target.
# hw:0,0 is a guess until a real unit says otherwise.
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

cat > "$OVERLAY_DIR/etc/init.d/S50mpd" <<'EOF'
#!/bin/sh
# Phase 1 placeholder. runit takes this over in Phase 3.
# Writable dirs are created by inittab sysinit, on tmpfs.
case "$1" in
    start)
        printf 'Starting mpd: '
        /usr/bin/mpd /etc/mpd.conf && echo OK || echo FAIL
        ;;
    stop)
        /usr/bin/mpd --kill /etc/mpd.conf 2>/dev/null || true
        ;;
    restart)
        "$0" stop; sleep 1; "$0" start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"; exit 1
        ;;
esac
EOF
chmod +x "$OVERLAY_DIR/etc/init.d/S50mpd"

# ---------------------------------------------------------------------
# Disk image layout
# ---------------------------------------------------------------------
#
# Boot partition offset is pinned at 1 MiB so post-image.sh can hand
# syslinux a hardcoded offset rather than parsing it back out.
#
# 64M, not 32M: 32M lands on the FAT32 cluster-count boundary and
# mkdosfs may quietly give you FAT16 under a 0x0C partition type.

log "Writing genimage config"

cat > "$BOARD_DIR/genimage.cfg" <<'EOF'
image boot.vfat {
  vfat {
    label = "SLMPBOOT"
  }
  files = { "bzImage", "syslinux.cfg", "ldlinux.c32" }
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

# post-image.sh: this is where the previous version fell down. genimage
# assembles filesystems, it does not make anything bootable. The MBR
# boot code and ldlinux.sys both have to be written explicitly.
cat > "$BOARD_DIR/post-image.sh" <<EOF
#!/bin/sh
set -e

BOARD_DIR="\$(dirname "\$0")"
GENIMAGE_CFG="\$BOARD_DIR/genimage.cfg"
GENIMAGE_TMP="\${BUILD_DIR}/genimage.tmp"
IMG="\${BINARIES_DIR}/sdcard.img"
BOOT_OFFSET=$BOOT_OFFSET

cp "\$BOARD_DIR/syslinux.cfg" "\${BINARIES_DIR}/syslinux.cfg"

# ldlinux.c32 ships in one of two places depending on release.
for c in "\${HOST_DIR}/share/syslinux/ldlinux.c32" \\
         "\${HOST_DIR}/lib/syslinux/ldlinux.c32" \\
         "/usr/lib/syslinux/modules/bios/ldlinux.c32"; do
    [ -f "\$c" ] && cp "\$c" "\${BINARIES_DIR}/" && break
done
[ -f "\${BINARIES_DIR}/ldlinux.c32" ] || {
    echo "ERROR: ldlinux.c32 not found"; exit 1; }

rm -rf "\$GENIMAGE_TMP"
genimage \\
    --rootpath "\${TARGET_DIR}" \\
    --tmppath "\$GENIMAGE_TMP" \\
    --inputpath "\${BINARIES_DIR}" \\
    --outputpath "\${BINARIES_DIR}" \\
    --config "\$GENIMAGE_CFG"

# --- Make it bootable -------------------------------------------------

# 1. MBR boot code into the first 440 bytes, leaving the partition
#    table intact.
MBR=""
for m in "\${HOST_DIR}/share/syslinux/mbr.bin" \\
         "\${HOST_DIR}/lib/syslinux/mbr.bin" \\
         "/usr/lib/syslinux/mbr/mbr.bin" \\
         "/usr/lib/syslinux/mbr.bin"; do
    [ -f "\$m" ] && MBR="\$m" && break
done
[ -n "\$MBR" ] || { echo "ERROR: syslinux mbr.bin not found"; exit 1; }

dd if="\$MBR" of="\$IMG" bs=440 count=1 conv=notrunc status=none
echo "post-image: wrote MBR boot code from \$MBR"

# 2. ldlinux.sys into the FAT filesystem at the boot partition offset.
command -v syslinux >/dev/null 2>&1 || {
    echo "ERROR: host 'syslinux' installer not on PATH"; exit 1; }

syslinux --offset "\$BOOT_OFFSET" --install "\$IMG"
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

# --- System ------------------------------------------------------------
BR2_TARGET_GENERIC_HOSTNAME="slmp"
BR2_TARGET_GENERIC_ISSUE="super_lite_music_player"
BR2_INIT_BUSYBOX=y
BR2_TARGET_GENERIC_GETTY_PORT="tty1"
BR2_TARGET_GENERIC_ROOT_PASSWD="slmp"
BR2_ROOTFS_OVERLAY="$OVERLAY_DIR"
BR2_ROOTFS_POST_IMAGE_SCRIPT="$BOARD_DIR/post-image.sh"
# Network config comes from the overlay, not from BR2_SYSTEM_DHCP.

# --- Kernel ------------------------------------------------------------
BR2_LINUX_KERNEL=y
BR2_LINUX_KERNEL_CUSTOM_VERSION=y
BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="$KERNEL_VERSION"
BR2_LINUX_KERNEL_DEFCONFIG="i386"
BR2_LINUX_KERNEL_USE_DEFCONFIG=y
BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="$BOARD_DIR/linux.fragment"
BR2_LINUX_KERNEL_BZIMAGE=y

# --- Filesystem --------------------------------------------------------
BR2_TARGET_ROOTFS_EXT2=y
BR2_TARGET_ROOTFS_EXT2_4=y
BR2_TARGET_ROOTFS_EXT2_SIZE="400M"
BR2_TARGET_ROOTFS_TAR=y

# --- Bootloader --------------------------------------------------------
BR2_TARGET_SYSLINUX=y
BR2_TARGET_SYSLINUX_LEGACY_BIOS=y

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
BR2_PACKAGE_USBUTILS=y
BR2_PACKAGE_DROPBEAR=y
BR2_PACKAGE_STRACE=y

# --- Host tools --------------------------------------------------------
BR2_PACKAGE_HOST_GENIMAGE=y
BR2_PACKAGE_HOST_DOSFSTOOLS=y
BR2_PACKAGE_HOST_MTOOLS=y
EOF

# ---------------------------------------------------------------------
# Apply and validate
# ---------------------------------------------------------------------
#
# Buildroot silently drops defconfig symbols it does not recognise. On
# an unusual target that is how you end up debugging an image that was
# never built the way you thought it was.

log "Applying defconfig"
make -C "$BR_DIR" "${BOARD_NAME}_defconfig"

log "Validating that requested symbols survived"

DROPPED=0
while IFS= read -r line; do
    case "$line" in ""|"#"*) continue ;; esac
    sym="${line%%=*}"
    if ! grep -q "^${sym}=" "$BR_DIR/.config"; then
        warn "dropped or renamed: $sym"
        DROPPED=$((DROPPED + 1))
    fi
done < "$DEFCONFIG"

if [ "$DROPPED" -gt 0 ]; then
    warn "$DROPPED symbol(s) did not survive."
    warn "Inspect with:  make -C $BR_DIR menuconfig"
    warn "Package names drift between releases. Most likely movers:"
    warn "the MPD codec options and BR2_x86_geode."
    printf '\nContinue anyway? [y/N] '
    read -r reply
    case "$reply" in [yY]*) ;; *) die "Stopping so you can fix the defconfig." ;; esac
fi

# Belt and braces: confirm the one setting that matters most actually
# landed in the generated config.
if ! grep -q "^BR2_x86_geode=y" "$BR_DIR/.config"; then
    die "BR2_x86_geode did not survive. Without it the toolchain will
emit NOPL and nothing will boot. Fix this before building."
fi

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
# Report
# ---------------------------------------------------------------------

IMAGE="$BR_DIR/output/images/sdcard.img"
[ -f "$IMAGE" ] || die "Build finished but $IMAGE is missing. Check output/images/."

log "Done"
printf '  image:  %s\n' "$IMAGE"
printf '  size:   %s\n' "$(du -h "$IMAGE" | cut -f1)"

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
    lspci                 identify the real ethernet chip, then trim
                          linux.fragment down to just that driver
    aplay -l              confirm the Juli@ card index, fix mpd.conf
    mpc status            or: telnet localhost 6600

EOF