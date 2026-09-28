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
- [x] ~~Ethernet and DHCP.~~ `lspci` says VIA VT6105M [Rhine-III] at 00:0d.0,
      so `VIA_RHINE` is the driver and the shotgun has been removed.
- [x] ~~telnetd on port 23.~~
- [x] ~~Panel handshake accepted, all nine navigation and transport buttons
      reporting.~~
- [x] ~~Geode LX confirmed on silicon.~~ family 5 model 0xa, 498 MHz, and
      `/proc/cpuinfo` flags show `cmov mmx mmxext 3dnow 3dnowext` with **no SSE
      of any kind**. Geode AES engine and hardware RNG both initialise.
- [x] ~~MPD decodes and drives the card.~~ Verified with an HTTP stream:
      `pcm0p` reaches `RUNNING` with `hw_ptr` advancing.
- [x] ~~ESI Juli@ detected by ALSA, at card index 0.~~ `snd-ice1724` binds and
      `aplay -l` on the unit reports exactly what `mpd.conf` assumed: card 0
      device 0 is `ICE1724`, card 0 device 1 is `ICE1724 IEC958`, and nothing
      else claims an index. So `hw:0,1` addresses the right thing. Says
      nothing yet about whether audio reaches the S/PDIF socket.

### Blocked on a real unit

- [ ] **Confirm S/PDIF output now that `mpd.conf` points at `hw:0,1`.** MPD was
      playing happily to `hw:0,0`, the analog PCM, which produced no sound on
      the coax output. `aplay -l` on the unit now confirms the assumption:
      card 0 is the Juli@ and device 1 is `ICE1724 IEC958`, with nothing else
      competing for card 0. Still needs a listen.
- [x] **Watchdog works.** `acpi_enforce_resources=lax` was necessary and not
      sufficient: this BIOS had configured all eight MFGPT timers, and
      `scan_timers()` only counts one as free if its SETUP bit is clear, so
      geodewdt got nothing. `cs5535_mfgpt.mfgptfix=1` gives
      `7 MFGPT timers available`, `registered timer 1` and a real
      `/dev/watchdog`. Verified on hardware.
- [ ] Watch for side effects from `mfgptfix=1`. It forcibly resets timers the
      BIOS had set up for its own purposes, on a machine whose BIOS nobody has
      the source to. Nothing has misbehaved in a short test; leave it running
      for a while before trusting it.
- [ ] **USB DAC output.** Second `audio_output` block in `mpd.conf` is written
      but commented out. Enable and test.
- [ ] **`alsactl` mixer restore.** `S30alsa` now saves to
      `/data/alsa/asound.state` on shutdown and restores from it, falling back
      to `/etc/asound.state` as a factory default. So the unit will keep its
      own mixer settings once it has shut down cleanly at least once. Still
      worth capturing a known-good state into the overlay as the default,
      because the Juli@ probably comes up muted on a fresh card:
      `alsactl -f /etc/asound.state store` and copy that into
      `board/slmp/rootfs-overlay/etc/`.
- [x] **Identified which ethernet driver bound.** `lspci` on the unit says
      `00:0d.0 VIA Technologies VT6105M [Rhine-III]`, so `linux.fragment` is
      cut down to `VIA_RHINE` and the Realtek and NatSemi drivers are gone.

### Image trimming

Dead weight inherited from `i386_defconfig`, none of which exists on a Geode.
Leave it until the unit boots reliably — it is what makes KVM testing possible.

- [ ] Drop `SATA_AHCI`, `ATA_PIIX`, `ATA_GENERIC` once `PATA_CS5536` is confirmed.
- [ ] Drop `E1000`, `E1000E`, `VIRTIO_NET` and the 11 other virtio symbols.
- [x] ~~Trim the ethernet shotgun to whichever one `lspci` names.~~ It names
      VT6105M, so only `VIA_RHINE` is left.
- [ ] Drop `CFG80211`. It is built in from `i386_defconfig` and announces
      itself at every boot loading regulatory certificates, on a unit with no
      radio of any kind.

### Build system

- [x] ~~Get the config out of the build script.~~ `board/slmp/` and
      `configs/slmp_defconfig` are tracked files now; `phase 1.sh` dropped from
      1162 lines to 535 and holds no config. Verified byte-equivalent: the
      rootfs file list is identical and the only content difference is
      `/etc/shadow`, whose salt is random per build.
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

- [x] myMPD integrated and **running on a real BDP-1**. Buildroot package in
      `br2-external/package/mympd/`, built from the `src/mympd` submodule,
      served on port 80 from `S96mympd`. It answers in 15 ms, the JSON-RPC
      API returns live MPD state, and settings land in `/data/mympd/config`.
      Getting there took three hardware rounds; see
      [docs/mympd.md](docs/mympd.md).
- [x] Outbound HTTPS off. `MYMPD_WEBRADIODB=false` stops the one feature that
      phones home by itself, and the script-driven ones - lyrics fetching,
      ListenBrainz, fanart - cannot run at all because Lua is compiled out.
      `MYMPD_CERT_CHECK=false` is also required, not optional: without a CA
      bundle myMPD treats a missing certificate store as a fatal startup
      error and exits after binding port 80.
- [ ] Decide what happens when Phase 4 brings a pinned certificate. That is
      the point at which `ca_cert_store` has something real to point at and
      `cert_check` could go back on.
- [x] myMPD's settings persist. Work directory is `/data/mympd` on the
      data partition; the cache stays on tmpfs so cover art cannot wear
      the card. See [docs/storage.md](docs/storage.md).
- [x] myMPD runs as root on port 80, decided rather than deferred. A LAN
      appliance that already runs telnetd and MPD as root does not get
      safer by moving one daemon to 8080, and `http://<ip>/` is worth
      more than the gesture.
- [x] ~~NFS and SMB via MPD's storage plugins, not kernel mounts.~~ **Plan
      changed: it is not possible here.** `BR2_PACKAGE_MPD_LIBSMBCLIENT`
      `depends on BR2_TOOLCHAIN_USES_GLIBC` and `BR2_PACKAGE_SAMBA4`
      `depends on !BR2_TOOLCHAIN_USES_MUSL`, and this image is musl for size.
      Getting an `smb://` URI into myMPD's mount dialog would mean rebuilding
      every binary in the image against glibc. Shares are mounted by the
      kernel instead (`CONFIG_CIFS`), under `/media`, where MPD sees them as
      ordinary folders — see `/etc/default/shares`.
- [ ] Decide whether NFS is worth offering too. The kernel already has `nfs`
      and `nfs4` from `i386_defconfig`, so v4 costs nothing, but BusyBox's
      mount cannot do the userspace portmapper step v3 needs
      (`CONFIG_FEATURE_MOUNT_NFS` is off). `libnfs` via MPD's plugin has no
      glibc dependency and remains the better technical fit if the plugin
      route is ever wanted.
- [ ] Measure what MPD's first scan of a network share costs on this CPU, and
      whether the database on `/data` makes a rescan tolerable.
- [ ] Share configuration proven through the myMPD interface.
- [x] MPD database, state and playlists moved to `/data/mpd`, so the tag
      database is no longer rebuilt on every boot and playback resumes
      where it stopped. **Untested at scale** - the 30k-track question is
      now about how long the first scan takes, not about tmpfs.
- [x] `sticker_file` enabled, with `BR2_PACKAGE_MPD_SQLITE`. It needed
      somewhere persistent to live, which is why it arrived with the data
      partition.
- [ ] USB drives automount read-only under `/media`, which is MPD's music
      directory. Builds; no drive has been plugged into a real unit. Test
      FAT, exFAT, NTFS and ext4, and find out what a 500 MHz Geode can
      actually read a large exFAT volume at.
- [x] **UPnP/OpenHome renderer**, proposal 3.1, and the answer 3.3 gives to
      abandoning streaming services. upmpdcli, with OpenHome on so the
      renderer keeps its own playlist and can be gapless. It translates
      UPnP into MPD commands and never touches ALSA, so the S/PDIF path is
      untouched. **Builds; never run.**
- [x] Decoder coverage widened for it, because a renderer plays whatever a
      control point pushes. ffmpeg as the catch-all (ALAC, WMA, WAV, and
      anything else), faad2 ahead of it for AAC so the dedicated decoder
      wins - AAC is known to play on this hardware under the stock 3.12
      firmware. Costs about 14 MB of ffmpeg libraries.
- [ ] Listen to it. Nothing here is verified: not the renderer appearing in
      a control point, not gapless, not whether ffmpeg's ALAC keeps up on a
      500 MHz core with its assembly disabled.
- [ ] Consider trimming ffmpeg's decoders to an audio-only list. Everything
      is on at the moment, video included, which is most of those 14 MB. It
      was left that way deliberately - enumerating codecs is how you find
      out eighteen months later which one you forgot - but the video half
      is provably dead weight on a machine whose only output is S/PDIF.

---

## Phase 3: Panel daemon

`src/panel/bdp-panel.c` is the link layer, and now also the player front end:
it follows MPD over `libmpdclient` and maps the transport keys onto it. What
is still to come is the menu tree, the settings web UI and the watchdog - the
three things proposal 4.4 puts in the same process.

### Protocol gaps

- [ ] **Does the display work?** `bdp-panel -1 "one" -2 "two"`. The `0A 0D`
      terminator is confirmed for the enable command only; it is applied to
      line 1 and line 2 on the assumption that framing is uniform. `-L` sends
      LF alone if that assumption is wrong.
- [ ] **Line width.** Unknown, and deliberately not guessed at: an over-long
      line just runs off the end, so `bdp-panel` clips nothing by default and
      the unknown costs nothing today. It is needed for scrolling, which does
      have to know where the end is. Measure it with
      `bdp-panel -1 '....5...10...15...20...25'` and count, then set `-w`.
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
- [x] ~~Decide tap-versus-hold semantics.~~ Decided: act on the **press**, and
      suppress the repeats the panel sends while a button is held, so one
      press is one action. `BDP_POLL` resuming is what re-arms. PTY-tested -
      five NEXTs with no POLL between produce one skip.

      This gives up what the stock firmware bought by acting on *release*:
      it could tell a tap from a hold and turn a held NEXT into a seek.
      Skipping reliably is worth more than an unimplemented seek, but adding
      seek later means going back to release-based handling, so the cost is
      real rather than theoretical.
- [ ] Seek on hold, if it turns out to be wanted. See above for what it
      costs.

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
- [x] MPD integration over `libmpdclient`. One connection held in `idle`,
      polled alongside the panel UART in one loop. Transport keys mapped,
      one action per press with hold repeats suppressed, `BDP-1 Ready` when
      stopped, title and artist when playing. **Built and PTY-tested; the
      display has still never shown anything on real hardware.**
- [ ] Scrolling long titles on a 200-300 ms tick. Nothing is clipped now, so a
      long title runs off the end of the panel; scrolling is what actually
      fixes that, and unlike clipping it does need the real width.

- [x] Only write bytes when the rendered line differs from what is on screen.
- [ ] Settings web UI on a separate port, via civetweb. This is where network
      shares belong: myMPD's Mounts page drives MPD's `mount` command and has
      nothing to talk to on a musl image, so adding or changing a share is
      currently a file edit over ssh. Also network configuration, update
      control, and a log view. Do **not** solve this by forking myMPD's C:
      mounting filesystems is not a music player's job, myMPD already runs as
      root, and every feature added to a 100k-line upstream project is a
      permanent merge conflict.
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
- [x] Confirmed on hardware that the data partition grows, reboots and
      formats correctly, leaving exactly 400 MB free for the B slot.
- [x] Persistent config partition. p3, grown to fill the card on first
      boot, with 400 MB deliberately left free at the end of the card for
      the B slot. `RESERVE_MB` in `S03data` must stay equal to the rootfs
      size in `genimage.cfg`.
- [ ] A/B rootfs slots. The space is reserved; the B slot becomes p4. The
      400 MB single root is still oversized for its 46 MB of content, so
      consider shrinking both slots before committing to the layout.
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
- [x] **Persistent dropbear host keys.** `/etc/dropbear` is now a symlink to
      `/data/dropbear`, which also stops Buildroot's `S50dropbear` from
      falling back to regenerating them into tmpfs.

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
- [ ] myMPD serves port 80 as root, and now upmpdcli answers SSDP and HTTP
      too. Both were accepted deliberately for a LAN appliance - see Phase 2 -
      but the network-facing surface has grown from "a telnet daemon" to
      "a web server and a UPnP stack", and that is worth restating rather
      than leaving implied.
- [ ] `MYMPD_CERT_CHECK=false`. Harmless while nothing makes an outbound TLS
      connection, which is the case today. It stops being harmless the moment
      something does.

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
