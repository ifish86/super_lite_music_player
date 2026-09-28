# Geode Player: Community Firmware Proposal

**Author:** Chris Rice **Date:** 25 September 2026 **Status:** Draft for discussion

---

## 1. Summary

The Geode-based network music player has reached end of support. The cause is not hardware failure or a lack of demand, but a platform mismatch: the current control stack depends on Node.js, and Node cannot run on this CPU at any version.

This proposal covers taking over support as an independent personal project. The approach is to rebuild the firmware from the ground up using only software that fits the hardware, replacing the Node control layer with a C/C++ stack, and distributing it as a signed A/B updatable image.

The goal is a player that works indefinitely without depending on any external service, and that degrades gracefully if the project is eventually abandoned.

---

## 2. Background

### 2.1 Hardware

| Component | Detail |
| --- | --- |
| CPU | AMD Geode LX, \~500 MHz |
| RAM | 256 MB |
| Storage | 4 GB CompactFlash (True IDE mode) |
| Audio | ESI Juli@ (Envy24HT / ICE1724), S/PDIF coax out |
| Audio (alt) | USB DAC output |
| Network | 100 Mbit ethernet |
| Front panel | 2-line display plus 8 buttons, serial link to mainboard |

### 2.2 Why support ended

The product ecosystem moved to a Node.js based control and UI layer. V8's ia32 backend assumes SSE2 as a baseline instruction set. The Geode LX has no SSE at all, only MMX, MMXEXT, 3DNow! and 3DNowEXT. This is not a build configuration problem. No version of Node.js can execute on this silicon, and Node has been winding down 32-bit support generally (32-bit Linux demoted to experimental at v10, 32-bit Windows removed at v23).

A secondary factor is library scale. MPD's in-memory database against 256 MB of RAM struggles at 100,000 tracks.

### 2.3 The CPU is not actually the obstacle

Worth stating clearly, because it shapes the whole plan. The Geode LX reports as CPU family 5, but its flag set includes `cmov`, `mmx`, `mmxext`, `3dnow` and `3dnowext`. The only instruction it lacks relative to i686 is the long NOP (NOPL).

That single missing instruction is why stock i686 distribution binaries fault on it. It is not why modern software fails to run. Anything compiled with `-march=geode` works fine. The constraint is that nobody ships prebuilt binaries targeting it anymore, so the firmware must be built from source.

---

## 3. Scope

### 3.1 In scope

- Buildroot-based firmware image targeting `-march=geode`
- Local file playback (all formats MPD supports on this hardware)
- Network share access (NFS, SMB)
- Web UI for browsing, playback and queue management
- Front panel display and button handling
- Network configuration (wired, and WiFi via USB dongle)
- Signed A/B firmware updates with rollback
- UPnP/DLNA renderer support

### 3.2 Out of scope

- Streaming service integration (Tidal, Qobuz, Spotify)
- Any feature requiring a JavaScript runtime on device
- Libraries beyond roughly 30,000 tracks indexed locally
- Any hosted service that must remain running for the product to work

### 3.3 Streaming services: explicitly abandoned

This deserves its own note because it will be the most asked-about gap. Streaming service integration is a permanent treadmill of API changes, OAuth token refresh and TLS requirement churn. A 500 MHz CPU with no AES-NI, doing TLS 1.3 while decoding, is a poor place to stand on that treadmill.

Users who want streaming should point a modern renderer at the unit, or use its UPnP support with a control point that handles the service side.

---

## 4. Architecture

### 4.1 Principle

The Geode is a playback endpoint, not an application host. Everything that can live off the box, does. What remains on device is chosen for its ability to run in a few megabytes of RAM with no runtime.

### 4.2 Stack

```
BusyBox init (PID 1)
  └── runsvdir /etc/service
        ├── bdp-panel      (custom, C++)
        ├── mpd
        ├── mympd
        └── wpa_supplicant
```

| Layer | Choice | Rationale |
| --- | --- | --- |
| Build system | Buildroot | Has a Geode x86 variant; cross-compiles on a modern host |
| Init | BusyBox init | Whole base userland in \~1 MB |
| Supervision | runit | Restart backoff, `sv down` actually keeps a service down |
| Userland | BusyBox | ash, mdev, udhcpc, ntpd, syslogd, ifupdown, crond |
| Player | MPD | Stable, C++, already the existing engine |
| Web UI | myMPD | C backend, no external webserver or database |
| TLS | mbedTLS | Small, Apache 2.0, no SIMD assumptions |
| Signatures | Monocypher | Public domain, \~10 KB for Ed25519 verification |
| HTTP (custom) | civetweb | MIT licensed, C with a C++ interface |
| MPD client lib | libmpdclient | BSD, handles the protocol |

Estimated image size: 25 to 40 MB. That leaves two A/B slots and a config partition sitting comfortably on a 4 GB card.

### 4.3 Why myMPD rather than a custom web UI

myMPD's backend is C with no dependency on an external database or webserver, and the frontend is a plain JavaScript PWA. Critically, all data is pulled on demand from MPD, and MPD's database is the only source of truth. It does not hold a second copy of the library in RAM, which on a 256 MB machine is the difference between viable and not.

It also already includes MPD mount and neighbors support, so network share configuration is a solved UI problem.

Build configuration will compile out the features that make outbound HTTPS calls (lyrics fetching, ListenBrainz, fanart, webradio directory).

### 4.4 The custom daemon: `bdp-panel`

One C++ binary, one process, shared state. It owns:

- Front panel display rendering and button input
- The settings web UI (network, WiFi, update control) on a separate port
- The update agent (manifest check, download, signature verify, slot write)
- Petting the hardware watchdog from its main loop

**Why one process and not three.** The front panel must keep working during a firmware update. Showing "Updating, do not power off" on two lines is not optional UX when the alternative is a customer pulling the plug mid-write. Sharing state in one address space is far simpler than coordinating three daemons over IPC.

**Threading model.** One thread running a poll loop over the MPD socket, the panel serial fd and a timerfd. civetweb's HTTP workers touch shared state behind a mutex.

**Display handling.** Subscribe to MPD's `idle` and re-render on change, plus a fixed 200 to 300 ms tick for scrolling long titles. Only write bytes to the serial link when the rendered line differs from what is already on screen, to avoid saturating a slow UART.

### 4.5 Network shares

**Revised after Phase 2. The original plan was not possible.** It read: handled by MPD's storage plugins in userspace, not by kernel mounts, on the grounds that this removes any need for util-linux, nfs-utils or cifs-utils, none of which BusyBox provides.

MPD's SMB storage plugin cannot be built here. `BR2_PACKAGE_MPD_LIBSMBCLIENT` depends on `BR2_TOOLCHAIN_USES_GLIBC`, and the `BR2_PACKAGE_SAMBA4` it selects depends on `!BR2_TOOLCHAIN_USES_MUSL`. This image is musl, chosen for size in §4.2, so the plugin route would mean rebuilding every binary in the image against glibc and adding samba4, python and gnutls — to gain a mount dialog.

Shares are therefore mounted by the kernel (`CONFIG_CIFS`) under `/media`, which is MPD's `music_directory`, and MPD treats them as ordinary directories. The stated benefit of the plugin route turned out to be largely illusory: this needs no userspace packages either. BusyBox's `mount` has `FEATURE_MOUNT_CIFS` compiled in already and the kernel does the work, so util-linux, nfs-utils and cifs-utils are still all absent.

What is genuinely lost is myMPD's *Mounts* page, which drives MPD's `mount` command and so has nothing to talk to. Configuring a share is a file — `/etc/default/shares`, overridden by `/data/shares/shares.conf` on the persistent partition — until the settings UI in §4.4 exists, where it belongs alongside network configuration.

libnfs remains the better technical fit for NFS and has no glibc dependency, so the plugin route stays open for NFS specifically if it is ever wanted. The kernel already carries `nfs` and `nfs4` at no cost; NFSv3 is not usable because BusyBox's mount cannot do the portmapper step it needs.

### 4.6 Network configuration

- **Wired:** BusyBox ifupdown and udhcpc, with `/etc/network/interfaces` rewritten from the settings UI.
- **WiFi:** wpa_supplicant driven through its control socket rather than by shelling out to `wpa_cli`.

WiFi requires a USB dongle, which means driver and firmware blobs in the image and USB work on a CPU that is also decoding. Streaming 24/192 from a NAS over USB WiFi on this hardware is not comfortable. WiFi will be supported where it works, with documentation stating clearly that ethernet is the supported path.

---

## 5. Front panel design

### 5.1 Available input

Up, Down, Left, Right, Previous, Play, Pause, Stop, Next.

The dedicated transport row is an advantage: those buttons never need to be borrowed for menu duty, so there is no mode ambiguity about what a button currently does.

### 5.2 Navigation model

| Action | Binding |
| --- | --- |
| Move within a menu | Up / Down |
| Enter submenu, commit value | Right |
| Back out | Left |
| Destructive confirm | Hold Left + Right, 2 s, with on-screen countdown |
| Return to now playing | Automatic after 60 s idle |

There is no dedicated select button, so Right doubles as enter. This is how car stereos and rack gear have always worked and needs no explanation to users.

Menu timeout matters more than it sounds. Without it, a unit gets left three levels deep in a settings tree and looks broken to the next person who walks up to it.

### 5.3 Text entry

Required for WPA passphrases. Up and Down cycle the character, Right advances position, Left backspaces, hold Right commits. Raw string shown on line two with a cursor marker. Character set ordered lowercase, uppercase, digits, symbols so users are not scrolling through punctuation to reach a common letter.

This is miserable and that is accepted. It is the recovery path, not the normal path. Nobody enters a 63-character PSK this way twice.

### 5.4 Panel scope

The panel is a status display with an escape hatch, not a full settings interface. It handles playback, browsing, showing the current IP, and enough network configuration to reach the web UI. Everything else lives in the browser.

This keeps the menu tree shallow enough that four navigation buttons stay comfortable, and avoids maintaining two parallel implementations of every setting.

---

## 6. Update system

### 6.1 A/B slots

Two rootfs slots plus a persistent config partition. The running rootfs is never written to. syslinux's `--once` mode boots a label exactly once and reverts, giving failed-boot recovery without a boot counter.

SWUpdate should be evaluated before writing anything custom. It is Buildroot-integrated, works on x86, and handles signed artifact verification natively.

### 6.2 Certificate rot is the real risk

A frozen image with a frozen CA bundle will eventually be unable to reach any update server, and it will happen years after anyone is thinking about it. The DST Root CA X3 expiry in 2021 broke update checks on a great deal of embedded hardware for exactly this reason.

Two mitigations, both cheap:

1. **Sign the update artifacts with an offline key** and verify on device after download. TLS then provides privacy, not the security boundary, and a TLS failure degrades to "cannot reach server" rather than "silently accepts anything".
2. **Pin a self-controlled root** rather than trusting the public CA system, so the project is not subject to anyone else's rotation schedule.

### 6.3 Hosting

No update server will be operated. GitHub Releases plus a static JSON manifest provides a versioned endpoint with working TLS at no cost, and does not depend on anyone paying a bill or renewing a domain in 2031. Artifacts are signed regardless, so hosting can move later without consequence.

### 6.4 Designed for eventual abandonment

This is a personal project and may not be maintained forever. The update check is therefore opt-in, non-blocking, and completely irrelevant to playback. A unit that never contacts anything must work identically, forever. A dead endpoint must produce silence in the logs, not a degraded user experience.

---

## 7. Reliability

| Mechanism | Covers |
| --- | --- |
| runit supervision | Daemon crashes, with automatic restart backoff |
| CS5536 hardware watchdog | Hangs, petted by `bdp-panel`'s main loop |
| A/B slots with syslinux `--once` | Failed boot after update |
| Read-only root, tmpfs overlay | CF wear |

The watchdog is deliberately petted by the panel daemon rather than by BusyBox's watchdog applet. A hung panel daemon should reboot the unit, not sit there with a frozen display. That is the failure mode that actually needs covering.

Service logs go to tmpfs via `svlogd` with size caps, never to the CF card.

---

## 8. Risks

| Risk | Severity | Mitigation |
| --- | --- | --- |
| CF card death | High | Image existing cards immediately; source industrial SLC replacements; read-only root |
| Front panel protocol undocumented | High | Capture with a logic analyser while a known-good unit exists |
| Original source unavailable | Medium | Request release from the company; otherwise reimplement from captured protocol |
| Library size ceiling | Medium | Document honestly; MPD proxy database plugin where a larger machine exists |
| USB WiFi firmware under mdev | Low | mdev's hotplug helper is fiddlier than udev for firmware blobs |
| CMOS battery death | Low | Cheap to preempt; a dead cell means lost BIOS settings and no boot |
| PSU electrolytics | Low | 15-year-old units; recap as preventive maintenance |

### 8.1 Unresolved: IP and permission

Taking over support of a former employer's product personally has edges around firmware source ownership, trademark use, and what is implicitly promised to customers. This should be settled in writing before anything is published.

The likely upside: a company already dropping support has little reason to withhold the source. If the existing firmware and panel protocol documentation can be released or licensed, the reverse engineering phase disappears entirely.

---

## 9. Phases

### Phase 0: Preservation

Not optional and not deferrable. Every later step is reversible with these artifacts and unrecoverable without them.

- Image existing CF cards, multiple copies, checksummed, stored off site
- Capture the front panel serial protocol in both directions
- Source spare industrial SLC CF cards
- Confirm whether buttons send discrete press and release events, or a single event per press (hold-to-confirm and scroll repeat both need release events)

### Phase 1: Base image

- Buildroot configuration targeting `-march=geode`
- Kernel with `CONFIG_MGEODE_LX`, `snd-ice1724`
- BusyBox userland, runit supervision
- MPD building and playing to both S/PDIF and USB
- Verify `alsactl` restores Juli@ mixer state at boot

### Phase 2: Web UI

- myMPD integrated, outbound-HTTPS features compiled out
- NFS and SMB storage plugins, RSS measured for both
- Share configuration proven through the myMPD interface

### Phase 3: Panel daemon

- Serial protocol driver, display rendering, button handling
- Menu tree and text entry
- Settings web UI for network and WiFi
- Watchdog integration

### Phase 4: Update system

- A/B partitioning and syslinux `--once` rollback
- Ed25519 artifact signing and on-device verification
- Manifest check against GitHub Releases
- Panel messaging during update

### Phase 5: Release

- Documentation, including honest statements of limitations
- USB stick recovery config path
- Source published

---

## 10. Open questions

1. Is the original build tree and toolchain available, or does this start from the CF image alone?
2. Is the panel protocol framed with checksums, and can button events arrive mid-write during a display update? Half-duplex collisions on that link are the kind of bug that appears once every few hundred hours and takes a week to find.
3. How many units are in the field, and is this for personal use or for other owners to run?
4. Will the company release the firmware source and protocol documentation?

---

## 11. Bootstrap requirement

One design constraint that cuts across everything above: if the network is misconfigured, the web UI is unreachable, and a two-line display is not a realistic way to enter a WPA passphrase.

At least three escape hatches are therefore mandatory:

1. The panel always displays the current IP address, so the UI can be found at all.
2. A config file read from a USB stick at boot. Drop in SSID and PSK, plug in, reboot. Ugly, but it never fails and costs roughly fifty lines of code.
3. Ethernet always falls back to DHCP regardless of stored configuration.
