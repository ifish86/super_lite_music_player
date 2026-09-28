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
| Boots on the real unit from CF | yes |
| Ethernet + DHCP | yes, VIA VT6105M Rhine-III |
| telnet / ssh access | yes |
| Front panel handshake | yes |
| Front panel buttons | yes, all nine navigation and transport keys |
| Front panel display | **untested** — `bdp-panel` now drives it from MPD, unverified |
| Juli@ detected by ALSA | yes, card 0, IEC958 on device 1 — as `mpd.conf` assumes |
| Playback to S/PDIF | **untested** |
| Data partition grows and formats on first boot | yes, 2.9 GB on a 4 GB card |
| Settings survive a reboot | yes, `/data` holds myMPD's config and MPD's database |
| Watchdog | yes, `/dev/watchdog` exists — needed `cs5535_mfgpt.mfgptfix=1` |
| MPD running | yes |
| Web UI (myMPD) | yes, serves on port 80 in 15 ms and talks to MPD |
| USB drive automount | builds, **never had a drive plugged into a real unit** |
| UPnP/OpenHome renderer | upmpdcli builds and is in the image, **never run** |
| A/B updates | not started, Phase 4 |

It took three hardware rounds to get the Phase 2 image up, written up in
[docs/storage.md](docs/storage.md#what-the-first-hardware-run-found) and
[docs/mympd.md](docs/mympd.md). The storage work behaved exactly as designed;
what stopped it were a missing empty directory, a BIOS that had claimed every
watchdog timer, and a certificate store myMPD refuses to start without.

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
myMPD 26 for the web UI, dropbear, telnetd, and `bdp-panel`. Root is ext4
mounted read-only. Things that write and matter — settings, SSH host keys, the
MPD database — go to a third partition mounted at `/data`; things that write
and do not matter go to tmpfs. That split is what keeps the CF card alive.

USB drives mount themselves read-only under `/media`, which is also MPD's
music directory. FAT, exFAT, NTFS and ext4 are all built into the kernel.

Buildroot 2025.02.9 builds the toolchain and packages. The resulting
`sdcard.img` is ~465 MB: a 64 MB FAT32 boot partition at 1 MiB offset, a
400 MB ext4 root of which about 46 MB is occupied, and an 8 MB placeholder for
the data partition. On first boot that last one grows to fill the card —
leaving 400 MB free at the end for the Phase 4 B slot — and gets a filesystem
made in it. [docs/storage.md](docs/storage.md) is the write-up.

myMPD is built from the submodule in `src/mympd` as a Buildroot package in
`br2-external/`. Getting it to cross-compile for this CPU took four
non-obvious changes, all written up in [docs/mympd.md](docs/mympd.md).

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
git submodule update --init --recursive
./phase\ 1.sh
```

The submodule is myMPD. Without it the script stops before building anything
and tells you so, rather than failing inside CMake half an hour later.

30 to 90 minutes. It downloads Buildroot, writes the defconfig, kernel fragment,
BusyBox fragment, rootfs overlay and genimage config, builds everything, and
produces `output/slmp-build/buildroot-2025.02.9/output/images/sdcard.img`.

Everything it generates lives under `output/`, which is gitignored and can be
deleted at any time. The configuration itself is tracked: `configs/` and
`board/slmp/` are real files, not generated ones.

### Rebuilding after a change

```bash
# changed src/panel/bdp-panel.c, or anything a package owns  -> 8 seconds
make -C output/slmp-build/buildroot-2025.02.9

# changed phase 1.sh itself, or want a known-good state      -> ~30 seconds
./phase\ 1.sh
```

Prefer `make -C` while iterating. Running the script re-copies the defconfig
and re-applies it, so `menuconfig` work is discarded — put config changes in
`configs/slmp_defconfig`, not in `menuconfig`.

On WSL, `make -C` skips the PATH sanitising that `phase 1.sh` does, so it is
the form that trips over a Windows PATH. See
[Things that will waste your time](#things-that-will-waste-your-time).

Edits to anything under `board/slmp/` need no script run at all: it is
symlinked into the Buildroot tree, so `make -C` picks them up directly.

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
- **ssh** — dropbear. Host keys are on `/data/dropbear` and survive reboots,
  so the changed-key warning on every connection is gone. If `/data` failed to
  mount, `S03data` falls back to a tmpfs and the old behaviour returns; check
  `grep data /var/log/messages` before blaming your client.

---

## The front panel

`src/panel/bdp-panel.c`. Protocol reverse-engineered from the stock firmware's
panel daemon (`brystonpanel.php`), then corrected against a real unit.

> That file is third-party Bryston code. It is **not distributed with this
> repository** — `assets/` is gitignored pending the IP and permission question
> in [TODO.md](TODO.md). Everything needed to talk to the panel is documented
> below, so you do not need it.

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

**There are no release events.** The panel sends one token per press and
repeats that token while the button is held; release is inferred from
`BDP_POLL` resuming. So `POLL` after `BDP_NEXT` is a tap, and `BDP_NEXT` after
`BDP_NEXT` is a hold. The stock firmware uses exactly this to make a tap skip
tracks and a hold seek within one — which is also why it acts on release
rather than on press. Hold-to-confirm and scroll-repeat are built on repeat
detection, not on release detection.

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

### Following MPD

Built with `MPD=1` — which the firmware build does — `bdp-panel` is also the
player front end. It holds one MPD connection in `idle` and polls that socket
alongside the panel UART in a single loop, so nothing is busy-waiting.

| | |
| --- | --- |
| MPD unreachable | line 1 `BDP-1`, line 2 stop icon + `Waiting for MPD`, retried every 2 s |
| connected, stopped | line 1 `BDP-1 Ready`, line 2 stop icon |
| playing or paused | line 1 title, line 2 play/pause icon + artist |

`BDP_PLAY`, `BDP_PAUSE`, `BDP_STOP`, `BDP_NEXT`, `BDP_PREVIOUS` and
`BDP_TOGGLE` map onto play, pause, stop, next, previous and toggle. `UP`,
`DOWN`, `LEFT`, `RIGHT` and `SHUTDOWN` are logged and do nothing yet — they
belong to the menu tree, which is still Phase 3 work.

**One action per press, not per repeat.** The panel repeats a token for as long
as a button is held and never reports a release, so the first sight of a token
is a press and every identical one after it is that same press continuing;
`BDP_POLL` resuming is what re-arms. Without this a held `NEXT` would skip a
dozen tracks. Verified against a PTY before it went near the hardware:

```
sent   : NEXT NEXT NEXT NEXT NEXT      -> 1 action
sent   : NEXT POLL NEXT                -> 2 actions
sent   : NEXT NEXT POLL NEXT NEXT      -> 2 actions
sent   : POLL POLL POLL POLL           -> 0 actions
```

This acts on the press, where the stock firmware acted on the release so it
could tell a tap from a hold and turn a held `NEXT` into a seek. Seeking is not
implemented; adding it later means going back to release-based handling.

Writes are compared against what is already on the line and skipped if
unchanged. At 9600 baud a full line costs about 23 ms, and MPD emits several
idle events per track change.

**Nothing is clipped by default**, and the unknown display width is therefore
not a problem. A line longer than the panel simply runs off the end, so
clipping to a guessed width could only discard characters the display would
have shown. What bounds a line is a 128-byte buffer, which is a limit on how
long one title may monopolise a 9600 baud link rather than a claim about the
hardware.

`-w COLS` imposes a real column limit for when the width is known and worth
respecting — scrolling long titles will need it, since scrolling has to know
where the end is. Find the number with a ruler and count what appears:

```bash
bdp-panel -1 '....5...10...15...20...25'
```

`-1` and `-2` deliberately bypass clipping, so the ruler is never the thing
being measured.

One consequence worth knowing: sending a title whole can now queue a few
hundred bytes, and the port is `O_NONBLOCK`, so `write()` can return `EAGAIN`
once the tty's output buffer fills. `write_all()` waits for writability rather
than treating that as a failure. It could not happen while lines were clipped
to twenty-odd bytes, which is why it was not handled before.

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
bdp-panel                          # enable, follow MPD, map the keys
bdp-panel -M                       # enable and log buttons, ignore MPD
bdp-panel -w 16                    # clip the display at 16 columns
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
make                                        # host build; MPD autodetected
make MPD=1                                  # require libmpdclient, fail without
make MPD=0                                  # link layer only
make CROSS_COMPILE=<buildroot>/output/host/bin/i586-linux- MPD=1
make CROSS_COMPILE=... check-geode          # fails on nopl or endbr32
```

MPD support is autodetected on a host that may not have libmpdclient, and
**required** in the firmware build, which passes `MPD=1`. Silently shipping a
panel daemon that cannot talk to MPD — one that comes up, holds the handshake
and then does nothing — is exactly the failure this avoids.

The detection asks the compiler that will do the build, so it consults the
right sysroot. It does this with `-include mpd/client.h` rather than by piping
a `#include` line in, because a `#` in a makefile must be written `\#`, make
passes the backslash through to the shell, and gcc then sees a line that is not
a directive at all: it preprocesses it happily and exits 0. That version of the
probe reported success on a machine with no libmpdclient anywhere.

The firmware build does this for you via a post-build hook, so the binary in
the image is always current with the source.

---

## Repo layout

```
phase 1.sh                        Orchestration: fetch, link, validate, build.
configs/slmp_defconfig            Buildroot configuration.
br2-external/                     Buildroot external tree: packages that are
  external.desc external.mk       ours rather than upstream's.
  Config.in
  package/mympd/                  myMPD, built from the src/mympd submodule.
board/slmp/
  linux.fragment                  Kernel config on top of i386_defconfig.
  busybox.fragment                BusyBox config deltas (telnetd).
  genimage.cfg                    Disk image layout.
  syslinux.cfg                    Bootloader config and kernel command line.
  post-build.sh                   Cross-compiles src/panel into the target.
  post-image.sh                   Runs genimage, then makes the image bootable.
  mdev-usb.conf                   USB automount rule, appended to mdev.conf.
  rootfs-overlay/                 Files dropped into the target filesystem:
    etc/inittab  etc/fstab  etc/mpd.conf  etc/network/interfaces
    etc/init.d/S01panel  etc/init.d/S30alsa  etc/default/bdp-panel
    etc/init.d/S03data   etc/init.d/S11usb  etc/dropbear -> /data/dropbear
    etc/init.d/S96mympd  etc/default/mympd
    usr/sbin/slmp-usb-mount
src/panel/bdp-panel.c             Front panel link.
src/panel/Makefile                Host and cross builds.
src/mympd/                        myMPD. Git submodule, not our code.
docs/project_proposal.md          Rationale, architecture, phase plan.
docs/mympd.md                     How myMPD was integrated, and why each
                                  build option is the way it is.
docs/storage.md                   The data partition, first-boot growth, and
                                  USB automount.
TODO.md                           What is left.
assets/old_programs/              Stock firmware sources. Gitignored, not distributed.
output/                           Build tree. Gitignored, regenerable.
```

Everything that makes this image what it is is an ordinary file under
`board/slmp/` or `configs/`. Change `mpd.conf`, commit `mpd.conf`, and the diff
says so. `phase 1.sh` symlinks `board/slmp` into the Buildroot tree and copies
the defconfig in, so the paths in `configs/slmp_defconfig` are relative to the
Buildroot tree exactly as every upstream Buildroot defconfig is.

`output/slmp-build/board/` no longer exists — it was generated, and it is gone.

---

## Extending the image

Both of the recipes below are ordinary file edits under `board/slmp/`, which is
symlinked into the Buildroot tree, so
`make -C output/slmp-build/buildroot-2025.02.9` picks them up with no sync step.
The one exception is `configs/slmp_defconfig`: the script copies that in and
applies it, so a change there needs `./phase\ 1.sh`.

### Adding a BusyBox applet

BusyBox's configuration is Buildroot's stock `package/busybox/busybox.config`
with `board/slmp/busybox.fragment` merged on top, and nothing else. That is why
the fragment is three lines rather than three thousand.

**1. Find the symbol name.** An applet is `CONFIG_<APPLET>`, but its
sub-options are not guessable from the name and its dependencies are not
visible at all:

```bash
grep -in tftp output/slmp-build/buildroot-2025.02.9/package/busybox/busybox.config
```

For the help text and the dependency tree, browse it instead:

```bash
make -C output/slmp-build/buildroot-2025.02.9 busybox-menuconfig
```

`/` searches. **Quit without saving.** Anything set there is untracked and is
overwritten the next time the fragment changes. `busybox-update-config`, which
would normally write a menuconfig session back to a tracked file, refuses
outright when config fragments are in use — the fragment is the only place this
can be written.

**2. Add it to `board/slmp/busybox.fragment`.** One symbol per line, with its
sub-options:

```
CONFIG_TFTP=y
CONFIG_FEATURE_TFTP_GET=y
```

To switch off something upstream enables, write `# CONFIG_FOO is not set`
rather than deleting a line. Deleting is how you undo your own addition: the
merge re-installs a fresh copy of `busybox.config` on every run, so a removed
line leaves no residue in the build tree.

**3. Rebuild.**

```bash
make -C output/slmp-build/buildroot-2025.02.9
```

The kconfig stamp depends on the fragment file itself, so a plain `make`
re-merges, re-runs `olddefconfig`, rebuilds BusyBox and repacks the rootfs. No
`busybox-dirclean`, no `busybox-reconfigure`.

**4. Check the symbol survived.** `olddefconfig` drops a symbol whose
dependencies are unmet without printing anything, which is the entire reason
for this step:

```bash
grep -E '^(# )?CONFIG_TFTP\b' \
  output/slmp-build/buildroot-2025.02.9/output/build/busybox-*/.config
```

A full `./phase\ 1.sh` run does this for every non-comment line of the fragment
and warns on each one that did not land. Nothing needs adding to the script —
it reads the fragment.

**5. Confirm the applet link.** BusyBox's install step creates the symlink into
`/bin`, `/sbin`, `/usr/bin` or `/usr/sbin` itself; you do not place it:

```bash
find output/slmp-build/buildroot-2025.02.9/output/target -lname '*busybox' -name tftp
```

**6. Start it, if it is a daemon.** Most applets get no init script. A few
arrive with one from Buildroot, conditionally — `CONFIG_FEATURE_TELNETD_STANDALONE=y`
is what installs `/etc/init.d/S50telnet`, and `package/busybox/` has the same
arrangement for `httpd`, `crond` and `watchdog`. For anything else, write the
init script yourself, as below.

### Adding another binary alongside bdp-panel

Same shape as `bdp-panel`: source in this repo under `src/`, cross-compiled
into the target by `board/slmp/post-build.sh`, configured from `/etc/default/`,
started from `/etc/init.d/`. Worked through here for a hypothetical
`slmp-web`.

**1. Put the source in `src/<name>/` with a Makefile.** Copy
`src/panel/Makefile` and change `BIN`. Three things in it matter: the tools are
prefixed with `$(CROSS_COMPILE)` rather than hardcoded, `-march=geode` is
deliberately *not* set (the Buildroot toolchain wrapper applies it from
`BR2_x86_geode`, and hardcoding it breaks the host build), and `check-geode`
greps the disassembly for NOPL so a bad build fails loudly.

**2. Add any library it links against to `configs/slmp_defconfig`.**
post-build runs at target-finalize, after every package is built, so staging is
complete by then and `-lmpdclient` resolves on its own — the cross gcc already
knows its sysroot. `$STAGING_DIR` is exported if an explicit path is needed.
A new `BR2_PACKAGE_...=y` line needs no change to `phase 1.sh`, whose defconfig check
reads every non-comment line of the defconfig, but it does mean re-running the
script rather than just `make -C`.

**3. Teach `board/slmp/post-build.sh` about it.** It currently hardcodes the
one program. Turn that into a list:

```sh
# One "<dir under src/>:<binary>" per program built from this repo.
PROGRAMS="panel:bdp-panel web:slmp-web"

for p in $PROGRAMS; do
	src="$BOARD_DIR/../../src/${p%%:*}"
	bin="${p##*:}"
	[ -f "$src/Makefile" ] || { echo "post-build: no $src, skipping"; continue; }
	make -C "$src" clean >/dev/null
	make -C "$src" CROSS_COMPILE="${CROSS_GCC%gcc}"
	install -D -m 0755 "$src/$bin" "$TARGET_DIR/usr/bin/$bin"
	make -C "$src" clean >/dev/null
	echo "post-build: installed /usr/bin/$bin"
done
```

The `clean` either side is not superstition: `src/` is also where you build by
hand, and without it the image can pick up a binary someone compiled for the
host. `BOARD_DIR` is resolved with `readlink -f` so `../../src` lands in the
repository rather than under `output/`. Buildroot exports `TARGET_DIR`,
`STAGING_DIR`, `HOST_DIR`, `BINARIES_DIR`, `BASE_DIR` and `BR2_CONFIG` to this
script; `TARGET_DIR` also arrives as `$1`.

**4. Add the config file** at
`board/slmp/rootfs-overlay/etc/default/<name>`, holding just the argument
string the init script sources. This is what lets the port, device or version
be changed on a running unit without a rebuild — see
`etc/default/bdp-panel` for the pattern.

**5. Write the init script** at
`board/slmp/rootfs-overlay/etc/init.d/S<NN><name>`, starting from `S01panel`.
Three rules:

- **Pick `NN` by what must already be running.** Current occupants: `S01panel`
  (first, because the handshake is what keeps the unit powered), `S01seedrng`,
  `S01syslogd`, `S02klogd`, `S02sysctl`, `S10mdev`, `S30alsa`, `S40network`,
  `S50crond`, `S50dropbear`, `S50telnet`, `S95mpd`. Something that needs the
  network is `S41` or later; something that talks to MPD's socket is `S96`.
- **No `.sh` suffix.** `rcS` *sources* `S*.sh` in its own shell rather than
  forking it, so a script that blocks, or that calls `exit`, takes init with it.
- **`chmod +x` it and commit the mode.** The overlay is rsync'd into the target
  with permissions intact, and `rcS` executes the file directly, so a 0644 init
  script is a permission-denied error on every boot.

**6. Keep runtime state on tmpfs.** Root is mounted `ro` and stays that way —
that is what keeps the CF card alive. `/var/log` and `/var/run` are skeleton
symlinks into `/tmp` and `/run`, so `>>/var/log/<name>.log` and a pidfile under
`/var/run` are both fine. `/etc` and `/usr` are not writable at all, so nothing
may expect to rewrite its own config.

**7. Add the binary to the NOPL check in `phase 1.sh`** — the
`for b in bin/busybox usr/bin/mpd` loop near the end. This is the one place
where adding a program does mean editing the script, and it is the check that
catches a binary the Geode cannot execute before you flash a card and find out
on the bench.

**8. Build and confirm it landed.**

```bash
make -C output/slmp-build/buildroot-2025.02.9
ls -l output/slmp-build/buildroot-2025.02.9/output/target/usr/bin/slmp-web
```

Third-party software that already carries its own build system does *not* go
through `post-build.sh`. That belongs in `br2-external/` as a real Buildroot
package — a `Config.in` and a `<pkg>.mk`. `br2-external/package/mympd/` is the
worked example, and [docs/mympd.md](docs/mympd.md) is the write-up of what it
took, including the three things that build cleanly and then produce an image
that does not run. `post-build.sh` is for our own source, where the whole build
is one `make`.

---

## Things that will waste your time

**The first boot reboots itself once.** `S03data` grows the data partition to
fill the card, and the kernel will not re-read a partition table while the
root filesystem is mounted off the same disk. So the first boot after flashing
rewrites the table and reboots. One reboot, once per card — but if you are
watching a unit come up for the first time and it restarts, that is why, and
`grep data /var/log/messages` will say so. Confirmed working on a BDP-1.

**Changing a package's sub-options does not rebuild that package.** Adding
`BR2_PACKAGE_MPD_FFMPEG=y` and `BR2_PACKAGE_MPD_FAAD2=y` builds ffmpeg and
faad2, and leaves MPD exactly as it was — already configured, already built,
linked against neither. The build succeeds and the feature is simply absent.
`readelf -d` on the binary is the check that does not lie; the fix is
`make -C <buildroot> mpd-dirclean` and a rebuild.

**Buildroot never deletes from `output/target`.** A package that stops
installing a file, or a hook you delete, leaves the file sitting in the target
directory and it goes on being baked into every image until something cleans
it. A real BDP-1 was found with `/var/lib/mympd` as a real directory long after
the hook that created it had been removed from `mympd.mk`. It was harmless that
time. It also means an incremental build and a from-scratch build of the same
tree can produce different images, and the incremental one is the one you have
been testing.

**A mountpoint that does not exist in the image cannot be created at boot.**
Obvious written down, invisible in practice: the root filesystem is read-only,
so `mkdir -p /data` in an init script fails, and then every `mount` onto it
fails too — including a tmpfs fallback whose whole job was to keep the unit
working. This cost a boot on real hardware. Buildroot's skeleton gives you
`/media` and `/mnt` and nothing else; anything else you intend to mount on
needs creating in `post-build.sh`.

**Stale image copies.** The build writes `sdcard.img` to the same path every
time with nothing to distinguish builds. If the unit does not have a change you
just made, check the timestamp on the file you actually flashed before
suspecting the build.

**WSL and PATH.** With no `/etc/wsl.conf`, `appendWindowsPath` defaults to true
and your PATH picks up `C:\Program Files\...`. Buildroot refuses any PATH
containing whitespace, from inside its own make rather than from a pre-flight
check of yours:

```
Your PATH contains spaces, TABs, and/or newline (\n) characters.
This doesn't work. Fix you PATH.
```

The typo is upstream's, which at least makes the message easy to search for. It
also rejects an empty element or a `.` separately, as *"You seem to have the
current working directory in your PATH"*.

`phase 1.sh` works around all three by rebuilding PATH from the usable entries
and dropping the rest, printing one `[warn] dropping PATH entry:` line each. On
WSL that is routinely a dozen lines and is not a sign anything is wrong.

**That workaround covers the script's own build and nothing else.** `make -C
output/slmp-build/...` — which the rebuild section above recommends for
iteration — runs with your login PATH and dies on the first make invocation.
Clean it for the one command:

```bash
PATH=$(echo "$PATH" | tr ':' '\n' | grep -vE '[[:space:]]|^\.?$' | paste -sd:) \
  make -C output/slmp-build/buildroot-2025.02.9
```

The real fix, once, is:

```ini
[interop]
appendWindowsPath = false
```

in `/etc/wsl.conf`, then `wsl --shutdown` from PowerShell. Nothing in a
Buildroot build wants the Windows PATH.

**Building on a Windows-backed mount.** DrvFs is dramatically slower for
many-small-file work and has no real ownership semantics. The script refuses to
start if `WORKDIR` is on one.

**Silently dropped config symbols.** Buildroot and kconfig drop symbols whose
dependencies are unmet without saying anything. `phase 1.sh` validates the
defconfig, the kernel fragment and the BusyBox fragment after the build and
fails loudly on the ones that matter. Those checks read the files themselves,
so a symbol you add is covered automatically. The two lists that are hardcoded
in the script, and so do need editing by hand, are `KERNEL_CRITICAL` — the
symbols worth aborting over rather than warning about — and the NOPL scan's
`for b in bin/busybox usr/bin/mpd`.

---

## Licence

See [LICENSE](LICENSE). `assets/old_programs/` contains third-party Bryston
code, is not covered by it, and is gitignored rather than redistributed.
