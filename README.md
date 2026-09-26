# super_lite_music_player

Replacement firmware for the Bryston BDP series network music players, built
from source for the AMD Geode LX.

The original product line reached end of support because its control stack
moved to Node.js, and V8's ia32 backend assumes SSE2. The Geode LX has no SSE
at all. No version of Node can execute on this silicon, at any build setting.

The CPU is not actually the problem. The Geode LX has `cmov`, `mmx`, `mmxext`,
`3dnow` and `3dnowext`; the only instruction it lacks relative to i686 is the
long NOP (`NOPL`), which is why stock i686 distribution binaries fault on it.
Anything compiled with `-march=geode` runs fine. Nobody ships prebuilt binaries
targeting it anymore, so the firmware is built from source.

See [docs/project_proposal.md](docs/project_proposal.md) for the full rationale,
architecture and phase plan. [TODO.md](TODO.md) is what is actually left to do.

---

## Status

Phase 1 (base image) builds and boots. The front panel link works on real
hardware. Most of the audio path has never been tested on a real unit.

| | |
| --- | --- |
| Builds and boots | yes, verified under KVM and on hardware |
| Front panel handshake | yes, verified on hardware |
| Front panel buttons | yes, all nine, verified on hardware |
| Front panel display | **untested** |
| Audio out | **untested** — no Juli@ in a VM, not yet tried on the unit |
| Watchdog | driver builds in, `/dev/watchdog` not yet confirmed on hardware |
| Web UI, A/B updates | not started, Phase 2 and 4 |

---

## Hardware

| Component | Detail |
| --- | --- |
| CPU | AMD Geode LX, ~500 MHz, no SSE |
| RAM | 256 MB |
| Storage | 4 GB CompactFlash, True IDE mode, on the CS5536 PATA channel |
| Audio | ESI Juli@ (Envy24HT / ICE1724), S/PDIF coax |
| Network | 100 Mbit ethernet |
| Front panel | 2-line display, 9 buttons, serial link on `/dev/ttyS1` |

---

## What is in the image

Linux 6.6 LTS built `-march=geode`, BusyBox userland and init, MPD 0.23,
dropbear, telnetd, and `bdp-panel`. Root is ext4 mounted read-only; everything
that writes goes to tmpfs, which is what keeps the CF card alive.

Buildroot 2025.02.9 builds the toolchain and packages. The resulting
`sdcard.img` is ~465 MB: a 64 MB FAT32 boot partition at 1 MiB offset and a
400 MB ext4 root.

---

## Building

### Host requirements

A Linux host, x86_64. WSL2 works; WSL1 does not, and the script will tell you
so. Never build on the target.

```bash
sudo apt install build-essential patch cpio unzip rsync bc wget file \
                 perl python3 util-linux xz-utils syslinux syslinux-common
```

`syslinux` and `syslinux-common` are not optional. The build takes the MBR boot
code, `ldlinux.c32` and the installer from the host package so all three are the
same syslinux version — mixing versions produces an image that builds cleanly
and then stops at the bootloader prompt.

### First build

```bash
./phase\ 1.sh
```

30 to 90 minutes. It downloads Buildroot, writes the defconfig, kernel fragment,
BusyBox fragment, rootfs overlay and genimage config, builds everything, and
produces `output/slmp-build/buildroot-2025.02.9/output/images/sdcard.img`.

Everything it generates lives under `output/`, which is gitignored. The script
is the source of truth for the configuration: it regenerates all of that on
every run.

### Rebuilding after a change

```bash
# changed src/panel/bdp-panel.c, or anything a package owns  -> 8 seconds
make -C output/slmp-build/buildroot-2025.02.9

# changed phase 1.sh itself, or want a known-good state      -> ~30 seconds
./phase\ 1.sh
```

Prefer `make -C` while iterating. Running the script wipes and regenerates the
rootfs overlay and re-applies the defconfig, so any `menuconfig` work or hand
edits under `output/slmp-build/board/` are discarded. If you want a config
change to survive, put it in `phase 1.sh`, not in `menuconfig`.

### Environment overrides

| Variable | Effect |
| --- | --- |
| `KERNEL_VERSION` | defaults to 6.6.100; checked against kernel.org before use |
| `BUILDROOT_VERSION` | defaults to 2025.02.9 |
| `WORKDIR` | build tree location; must contain no whitespace |
| `JOBS` | defaults to `nproc` |
| `SLMP_YES=1` | answer prompts with yes, for non-interactive runs |
| `SLMP_ALLOW_UNBOOTABLE=1` | build without host syslinux, producing an image that will not boot |

---

## Flashing

```bash
sudo dd if=output/slmp-build/buildroot-2025.02.9/output/images/sdcard.img \
        of=/dev/sdX bs=4M status=progress conv=fsync
```

Confirm `/dev/sdX` is the card and not your disk first.

On WSL2 there is no block device for a USB card reader. Copy the image to the
Windows side and use balenaEtcher, Rufus in DD mode, or Win32DiskImager:

```bash
cp output/slmp-build/buildroot-2025.02.9/output/images/sdcard.img /mnt/c/Users/$USER/Downloads/
```

The image is sparse: 465 MB apparent, ~33 MB allocated. `du` without
`--apparent-size` will understate it.

---

## Getting into a running unit

Login is `root` / `slmp`.

- **Serial/VGA console** — getty on tty1. Deliberately not on the panel UART.
- **telnet** — port 23, starts automatically. Plaintext, so wired LAN only.
- **ssh** — dropbear. Host keys live on tmpfs and are regenerated every boot,
  so your client will complain about a changed key each time. Until Phase 4
  gives them somewhere persistent to live:

  ```bash
  ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@<ip>
  ```

---

## The front panel

`src/panel/bdp-panel.c`. Protocol reverse-engineered from
[assets/old_programs/brystonpanel.php](assets/old_programs/brystonpanel.php),
the stock firmware's panel daemon, then corrected against a real unit.

9600 8N1 on `/dev/ttyS1`, raw, no flow control. Three commands out, all
terminated with **LF then CR — `0A 0D`, in that order, not CRLF**:

| Bytes | Meaning |
| --- | --- |
| `1C <version> 0A 0D` | enable. Must be sent first, and is what keeps the unit powered on |
| `11 <text> 0A 0D` | write line 1 |
| `12 <text> 0A 0D` | write line 2 |

Buttons arrive as newline-terminated ASCII: `BDP_POLL` (a continuous
heartbeat), `BDP_PLAY`, `BDP_PAUSE`, `BDP_STOP`, `BDP_NEXT`, `BDP_PREVIOUS`,
`BDP_TOGGLE`, `BDP_UP`, `BDP_DOWN`, `BDP_LEFT`, `BDP_RIGHT`, `BDP_SHUTDOWN`.

Line 2's first byte is conventionally a status icon: `0x91` play, `0x92` stop,
`0x93` pause, `0x95` directory, `0x96` file.

The working handshake on this unit is:

```
1C 53 33 2E 30 30 20 32 30 32 33 2D 30 34 2D 30 38 0A 0D
   S  3  .  0  0     2  0  2  3  -  0  4  -  0  8  \n \r
```

That string is the compiled-in default, so `bdp-panel` with no arguments sends
it. Two details the PHP gets wrong and that cost real debugging time: it
appends only `\n`, and it builds the version from `/ver` + `/datecode` as an
8-digit datecode rather than `YYYY-MM-DD`.

### Two termios traps

The line 1 command byte is `0x11`, which is **XON**. Leave `IXON` enabled and
the tty layer eats it as flow control, so line 1 writes silently vanish.

The status icons are `0x91`–`0x96`. `ISTRIP` would turn them into `0x11`–`0x16`,
which are themselves command bytes — that corrupts the stream rather than just
losing a glyph.

Both are cleared explicitly in `panel_open()` rather than via `cfmakeraw()`,
which is a BSD extension that does not compile against musl under
`_POSIX_C_SOURCE`.

### Running it

Starts automatically from `/etc/init.d/S01panel`, first in `rcS` — ahead of
syslog, network and everything else, because the handshake is what keeps the
unit powered. Button events go to `/var/log/bdp-panel.log` (tmpfs).

Arguments come from `/etc/default/bdp-panel`, so the port, version string or
raw handshake bytes can be changed on the unit without a rebuild.

```bash
bdp-panel                          # enable, then report button events
bdp-panel -1 "Line one" -2 "Two"   # write the display and exit
bdp-panel -i play -2 "Now Playing" # icon by name, avoids shell encoding issues
bdp-panel -D                       # dump the bytes, touch no hardware
bdp-panel -X '1C 53 33 ... 0A 0D'  # send exact bytes, nothing added
bdp-panel -L                       # terminate with LF only
```

`-X` ignores any non-hex character, so `x1C x53` and `1C 53` and `1c53` are all
the same. Use it when byte-matching against a capture.

### Building it standalone

```bash
cd src/panel
make                                        # host build, for -D and PTY testing
make CROSS_COMPILE=<buildroot>/output/host/bin/i586-linux-
make CROSS_COMPILE=... check-geode          # fails if any NOPL was emitted
```

The firmware build does this for you via a post-build hook, so the binary in
the image is always current with the source.

---

## Repo layout

```
phase 1.sh                        Phase 1 build. Source of truth for the config.
docs/project_proposal.md          Rationale, architecture, phase plan.
TODO.md                           What is left.
src/panel/bdp-panel.c             Front panel link.
src/panel/Makefile                Host and cross builds.
assets/old_programs/              Stock firmware sources, for reference.
output/                           Build tree. Gitignored, regenerable.
```

---

## Things that will waste your time

**Stale image copies.** The build writes `sdcard.img` to the same path every
time with nothing to distinguish builds. If the unit does not have a change you
just made, check the timestamp on the file you actually flashed before
suspecting the build.

**WSL and PATH.** With no `/etc/wsl.conf`, `appendWindowsPath` defaults to true
and your PATH picks up `C:\Program Files\...`. Buildroot refuses any PATH
containing whitespace, and it checks from inside the build rather than up
front. The script strips the offending entries, but the real fix is:

```ini
[interop]
appendWindowsPath = false
```

then `wsl --shutdown` from PowerShell.

**Building on a Windows-backed mount.** DrvFs is dramatically slower for
many-small-file work and has no real ownership semantics. The script refuses to
start if `WORKDIR` is on one.

**Silently dropped config symbols.** Buildroot and kconfig drop symbols whose
dependencies are unmet without saying anything. `phase 1.sh` validates the
defconfig, the kernel fragment and the BusyBox fragment after the build and
fails loudly on the ones that matter. If you add a symbol, add it to those
checks too.

---

## Licence

See [LICENSE](LICENSE). `assets/old_programs/` contains third-party code
included for reference and is not covered by it.
