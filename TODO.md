# TODO

Phase numbering follows [docs/project_proposal.md](docs/project_proposal.md).

Anything marked **unverified** builds and is believed correct but has never
been exercised on real hardware. Treat that distinction as load-bearing: this
project has already produced several things that were confidently wrong and
looked fine until a real unit disagreed.

---

## Phase 0: Preservation

Not optional and not deferrable. Every later step is reversible with these
artifacts and unrecoverable without them. **None of this is done.**

- [ ] Image the existing CF cards. Multiple copies, checksummed, stored off site.
- [ ] Source spare industrial SLC CF cards.
- [x] ~~Confirm whether buttons send discrete press *and* release events.~~
      **Answered.** There are no release events. The panel sends one token per
      press and *repeats* that token while the button is held; release is
      inferred from `BDP_POLL` resuming. The stock firmware relies on exactly
      this in `allThoseOtherCommands()`: `POLL` after `BDP_NEXT` means a tap, so
      `mpc next`; `BDP_NEXT` after `BDP_NEXT` means held, so seek. Hold-to-
      confirm and scroll-repeat are therefore implementable via repeat
      detection rather than release detection.
- [ ] Measure the repeat rate of a held button, which sets scroll and seek
      speed. The stock loop polls every 75 ms, which bounds it but does not
      give the panel's actual rate.
- [ ] Observe `BDP_TOGGLE` and `BDP_SHUTDOWN` live. The other nine tokens have
      been seen on hardware; these two have not.
- [ ] Capture the link with a logic analyser while a known-good unit still
      exists. Lower priority than it was — the protocol is understood and
      working — but it is still the only record that survives the unit dying,
      and it is the only way to answer whether the framing carries checksums
      and whether button events can arrive mid-write during a display update.
- [ ] Resolve the IP and permission question before anything is published.
      Firmware source ownership, trademark use, and what is implicitly
      promised to customers. Settle it in writing.

---

## Phase 1: Base image

Builds, boots, and the panel works. What remains is almost entirely
verification on hardware.

### Confirmed working on hardware

The unit boots from CF, gets a DHCP lease, and is reachable over telnet, with
the panel handshaking and reporting button presses.

- [x] ~~Boots on the real unit from CompactFlash.~~ Implies the CF enumerates
      through `PATA_CS5536` and the ext4 root mounts read-only as configured.
- [x] ~~Ethernet and DHCP.~~ One of the shotgun drivers binds the real chip.
      Which one is still unknown — see trimming below.
- [x] ~~telnetd on port 23.~~
- [x] ~~Panel handshake accepted, all nine navigation and transport buttons
      reporting.~~

### Blocked on a real unit

- [ ] **Audio.** Nothing about the audio path has been tested. Run `aplay -l`,
      confirm the Juli@ card index, and fix `hw:0,0` in the overlay's
      `mpd.conf` if it is wrong. Then actually play something to S/PDIF.
- [ ] **USB DAC output.** Second `audio_output` block in `mpd.conf` is written
      but commented out. Enable and test.
- [ ] **`alsactl` mixer restore.** `S30alsa` restores `/etc/asound.state` if it
      exists, and nothing creates that file yet. On a running unit:
      `alsactl -f /etc/asound.state store`, copy the result into the overlay in
      `phase 1.sh`, rebuild. Until then the Juli@ probably comes up muted.
- [ ] **Watchdog.** `CONFIG_GEODE_WDT` is compiled in and its `MFD_CS5535` and
      `CS5535_MFGPT` dependencies are satisfied, but `/dev/watchdog` has never
      been confirmed present on hardware. Check `dmesg | grep -i geode`.
- [ ] **Identify which ethernet driver actually bound.** Networking works, so
      this is now a trimming question rather than a functional one. `lspci` on
      the unit, then cut `linux.fragment` down to the one that matters.

### Image trimming

Dead weight inherited from `i386_defconfig`, none of which exists on a Geode.
Leave it until the unit boots reliably — it is what makes KVM testing possible.

- [ ] Drop `SATA_AHCI`, `ATA_PIIX`, `ATA_GENERIC` once `PATA_CS5536` is confirmed.
- [ ] Drop `E1000`, `E1000E`, `VIRTIO_NET` and the 11 other virtio symbols.
- [ ] Trim the ethernet shotgun (`VIA_RHINE`, `8139TOO`, `R8169`, `NATSEMI`)
      to whichever one `lspci` names.

### Build system

- [ ] **Stop rebuilding the kernel on every script run.** `phase 1.sh` rewrites
      `linux.fragment` and `busybox.fragment` unconditionally; the new mtime
      makes Buildroot reconfigure and relink both. Write-if-changed would make
      a no-op run nearly instant. (~30s today, so this is comfort, not urgency.)
- [ ] **Stamp the build.** Write `/etc/slmp-version` into the overlay with build
      time, kernel version and Buildroot version, so `cat /etc/slmp-version` on
      the unit answers "which image is this?" definitively. Two separate
      debugging sessions have already been lost to testing a stale copy.
- [ ] Consider naming images `slmp-<date>.img` rather than overwriting
      `sdcard.img`, for the same reason.

---

## Phase 2: Web UI

- [ ] myMPD integrated, with outbound-HTTPS features compiled out: lyrics
      fetching, ListenBrainz, fanart, webradio directory.
- [ ] NFS and SMB storage plugins via MPD's storage plugins, not kernel mounts.
      `libnfs` is the better technical fit; `libsmbclient` is heavy on 256 MB
      but most users' music is on SMB. Measure RSS both ways before deciding.
- [ ] Share configuration proven through the myMPD interface.
- [ ] Revisit the MPD database. It currently lives on tmpfs and is rebuilt every
      boot, which is fine at Phase 1 scale and unacceptable at 30k tracks.
- [ ] `sticker_file` is deliberately absent from `mpd.conf` — it needs
      `BR2_PACKAGE_MPD_SQLITE`, which myMPD will want.

---

## Phase 3: Panel daemon

`src/panel/bdp-panel.c` is the link layer and proves the protocol. The daemon
proper is still to come.

### Protocol gaps

- [ ] **Does the display work?** `bdp-panel -1 "one" -2 "two"`. The `0A 0D`
      terminator is confirmed for the enable command only; it is applied to
      line 1 and line 2 on the assumption that framing is uniform. `-L` sends
      LF alone if that assumption is wrong.
- [ ] **Line width.** Unknown. Nothing in the stock PHP truncates, so
      `bdp-panel` does not either. Find the real width and decide whether to
      truncate or scroll.
- [ ] **Is the handshake a one-shot or a keepalive?** If the panel needs
      re-arming periodically, a daemon that dies takes the unit down with it.
      Leave it running and find out.
- [ ] **Does re-sending the enable command do anything bad?** Determines whether
      a restarted daemon can safely re-handshake.
- [x] ~~Confirm the panel port.~~ `/dev/ttyS1`, verified on hardware. The stock
      PHP reads it from `/dev/shm/fpInt` and only falls back to `ttyS2`, which
      is why it never cared.
- [ ] Check `BDP_SHUTDOWN` behaviour. The stock firmware runs everything in
      `/shutdownTasks` and then `shutdown -h now`.
- [ ] Decide tap-versus-hold semantics. The stock firmware fires `mpc next` on
      *release*, not on press, so that a tap skips and a hold seeks. Worth
      keeping; it is not obvious from the outside.

### Daemon work

- [ ] Restart supervision. Nothing restarts `bdp-panel` if it dies today. runit
      is the Phase 3 answer; a BusyBox `respawn` line in inittab is the stopgap
      if this turns out to matter sooner.
- [ ] Menu tree and navigation: Up/Down to move, Right to enter and commit,
      Left to back out, 60 s idle timeout back to now-playing.
- [ ] Text entry for WPA passphrases. Up/Down cycle character, Right advances,
      Left backspaces, hold Right commits. Character set ordered lowercase,
      uppercase, digits, symbols.
- [ ] Hold Left+Right for 2 s with on-screen countdown for destructive confirms.
- [ ] MPD integration over `libmpdclient` — already in the image via `mpd-mpc`.
      Subscribe to `idle`, re-render on change, plus a 200–300 ms tick for
      scrolling long titles.
- [ ] Only write bytes when the rendered line differs from what is on screen.
      The UART is slow and saturating it is easy.
- [ ] Settings web UI on a separate port, via civetweb.
- [ ] Pet the CS5536 watchdog from the main loop. Deliberately not BusyBox's
      watchdog applet: a hung panel daemon should reboot the unit, not sit
      there with a frozen display.
- [ ] Move to a `BR2_EXTERNAL` tree. The current post-build hook that
      cross-compiles `src/panel` is a Phase 1 convenience, not the destination.
- [ ] runit supervision replacing the `S??` init scripts.

---

## Phase 4: Update system

- [ ] Evaluate SWUpdate before writing anything custom. It is Buildroot
      integrated, works on x86, and handles signed artifacts natively.
- [ ] A/B rootfs slots plus a persistent config partition. The 400 MB single
      root and `genimage.cfg` both need reworking.
- [ ] syslinux `--once` for failed-boot rollback. Note that `BR2_TARGET_SYSLINUX`
      installs nothing into the target, so the on-device `--once` writer needs
      to come from somewhere else.
- [ ] Ed25519 artifact signing with Monocypher, verified on device after
      download. TLS provides privacy, not the security boundary.
- [ ] Pin a self-controlled root rather than trusting the public CA system.
      A frozen CA bundle will eventually fail, years after anyone is thinking
      about it.
- [ ] Manifest check against GitHub Releases. Opt-in, non-blocking, irrelevant
      to playback. A dead endpoint must produce silence in the logs.
- [ ] Panel messaging during update. "Updating, do not power off" is not
      optional UX when the alternative is someone pulling the plug mid-write.
- [ ] **Persistent dropbear host keys.** They currently live on tmpfs and are
      regenerated every boot, so SSH clients warn about a changed key on every
      connection. The config partition is where they should live.

---

## Phase 5: Release

- [ ] Documentation, including honest statements of limitations.
- [ ] USB stick recovery config path: drop in SSID and PSK, plug in, reboot.
      Roughly fifty lines of code and it never fails.
- [ ] Ethernet DHCP fallback regardless of stored configuration — already in
      the overlay's `interfaces`, needs testing.
- [ ] Panel always displays the current IP so the web UI can be found.
- [ ] Publish source.

---

## Security debt

Fine for a bench unit, not fine for anything else. Revisit before release.

- [ ] Root password is `slmp`, baked into the image.
- [ ] telnetd on port 23, plaintext, enabled by default.
- [ ] No firewall of any kind.

---

## Open questions from the proposal

1. Is the original build tree and toolchain available, or does this start from
   the CF image alone?
2. Is the panel protocol framed with checksums, and can button events arrive
   mid-write during a display update? Half-duplex collisions on that link are
   the kind of bug that appears once every few hundred hours and takes a week
   to find.
3. How many units are in the field, and is this for personal use or for other
   owners to run?
4. Will the company release the firmware source and protocol documentation?
   Partially answered: `assets/old_programs/brystonpanel.php` gave up the panel
   protocol, which removed most of the reverse-engineering risk.
