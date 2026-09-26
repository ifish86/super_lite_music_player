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

BR_DIR="$WORKDIR/buildroot-$BUILDROOT_VERSION"
DL_DIR="$WORKDIR/dl"

# The things that make this image what it is live in the repository as
# ordinary files, not as heredocs in here. They are symlinked into the
# Buildroot tree so the defconfig can reference them the way every
# upstream Buildroot defconfig does, with paths relative to the tree.
BOARD_DIR="$SCRIPT_DIR/board/$BOARD_NAME"
OVERLAY_DIR="$BOARD_DIR/rootfs-overlay"
DEFCONFIG_SRC="$SCRIPT_DIR/configs/${BOARD_NAME}_defconfig"

# Buildroot reads this from the environment in preference to the config
# item, which is why the defconfig does not carry a download path.
export BR2_DL_DIR="$DL_DIR"

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

# Kernel symbols that must survive into the generated kernel .config or
# the image is not worth flashing. Checked after the build, because
# generating that .config needs the cross toolchain built first.
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
# Wire the board directory into the Buildroot tree
# ---------------------------------------------------------------------
#
# Symlinks rather than copies, so editing board/slmp/... in the repo
# takes effect on the next build with no sync step and no chance of the
# two drifting apart.

log "Linking board files into Buildroot"

for d in "$BOARD_DIR" "$OVERLAY_DIR"; do
    [ -d "$d" ] || die "missing $d
The board directory is part of the repository. If it is not there, the
checkout is incomplete."
done
[ -f "$DEFCONFIG_SRC" ] || die "missing $DEFCONFIG_SRC"

mkdir -p "$BR_DIR/board" "$BR_DIR/configs"
ln -sfn "$BOARD_DIR" "$BR_DIR/board/$BOARD_NAME"

DEFCONFIG="$BR_DIR/configs/${BOARD_NAME}_defconfig"
cp "$DEFCONFIG_SRC" "$DEFCONFIG"

# The defconfig pins the kernel. If KERNEL_VERSION was overridden, keep
# the version and its header series in step rather than letting them
# disagree, which is a failure that only shows up after the toolchain
# has been built.
PINNED="$(sed -n 's/^BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="\(.*\)"$/\1/p' "$DEFCONFIG")"
if [ "$PINNED" != "$KERNEL_VERSION" ]; then
    warn "defconfig pins kernel $PINNED, using $KERNEL_VERSION"
    sed -i "s|^BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE=.*|BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE=\"$KERNEL_VERSION\"|" "$DEFCONFIG"
    sed -i "s|^BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_[0-9_]*=y|${HEADERS_SYMBOL}=y|" "$DEFCONFIG"
fi

# Hand the resolved syslinux paths to post-image.sh as arguments. "none"
# rather than an empty string, because empty arguments vanish in the
# word splitting Buildroot does on this variable.
printf 'BR2_ROOTFS_POST_IMAGE_SCRIPT_ARGS="%s %s %s"\n' \
    "${SYSLINUX_BIN:-none}" "${SYSLINUX_MBR:-none}" "${SYSLINUX_C32:-none}" \
    >> "$DEFCONFIG"

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
