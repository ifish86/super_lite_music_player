# Persistent storage and removable media

Two related changes: a third partition that survives reboots, and USB drives
that mount themselves. They share a document because they share a design
decision — the read-only root stays read-only, and everything that needs to
write gets somewhere explicit to write to.

---

## Why not an overlay

The obvious answer to "make the settings persist" is an overlayfs with its
upper layer on a data partition. It was not taken, for one reason that is
worth writing down before someone tries it again.

The proposal commits to A/B rootfs slots. An overlay's upper layer accumulates
deltas against **one specific lower filesystem**. After an A/B switch, the
lower layer is a different image and every file in the upper layer silently
shadows its replacement: old config wins over new defaults, and if the overlay
covers `/usr`, an old library wins over the one the new version was built
against. Nothing errors. The unit boots into a mixture of two firmware
versions, and the symptom shows up somewhere unrelated to the cause.

A whole-root overlay also quietly retracts the thing the read-only root was
for. "The running rootfs is never written to" stops being true the moment
anything writes anywhere, and what gets written is no longer a decision anyone
made.

So: a plain data partition mounted at `/data`, and a handful of explicit
redirections into it. The redirections are greppable, they are version
independent, and an A/B switch cannot make them lie.

---

## Partition layout

```
p1  boot     64 MB   FAT32   bzImage, syslinux
p2  rootfs  400 MB   ext4    read-only, only 46 MB used
p3  data    grows    ext4    read-write, created on first boot
--  free    400 MB           reserved for the Phase 4 B slot
```

On a 4 GB card p3 ends up at about 2.9 GB. The reserve at the end is
deliberate: if p3 grew to fill the card, adding a B slot later would mean
shrinking a filesystem with live data in it. `RESERVE_MB` in
`/etc/init.d/S03data` has to stay equal to the rootfs size in `genimage.cfg`,
and there is a comment in both saying so.

The image itself ships p3 at **8 MB with no filesystem in it** — genimage
allows a partition with no `image`, which reserves the table entry and writes
nothing. That keeps `sdcard.img` at 465 MB apparent rather than the size of
the largest card anyone might use.

---

## First boot

Three states, derived from the disk rather than from a marker file, so the
sequence is idempotent and survives being interrupted:

1. **p3 is much smaller than the free space on the card** → rewrite its size
   in the partition table, reboot.
2. **p3 has no recognisable filesystem** → `mke2fs -t ext4`, mount.
3. **otherwise** → `e2fsck -p`, mount.

### Why it reboots

The kernel will not re-read a partition table while any partition on that disk
is mounted, and the root filesystem is on p2 of the same disk. `BLKRRPART`
returns `EBUSY`. The alternatives are `partx -u`, which means pulling in
util-linux and its four libraries for one ioctl, or a small C helper calling
`BLKPG_RESIZE_PARTITION`. A reboot that happens exactly once in the life of a
card is cheaper than either.

### Why it writes the partition table by hand

`S03data` does not use `fdisk`. It writes four bytes:

```sh
# MBR entry N is at 0x1BE + 16*(N-1). Entry 3: 0x1DE = 478.
# Its LBA sector count is at offset 12 within the entry: 490.
MBR_ENTRY3_SIZE_OFF=490
```

BusyBox `fdisk` is menu-driven, and scripting it means feeding a here-document
of `d`, `3`, `n`, `p`, `3`, start, end, `w` and hoping the prompt sequence
matches the applet that got compiled in. The partition start does not move and
the type does not change — the only thing that changes is the length — so
writing that one little-endian field is both shorter and deterministic.

This is only safe because of *when* it runs: the grow happens before the
filesystem is created, so there is never any data on p3 to lose. If it goes
wrong, the failure is "no data partition", which `S03data` handles.

It was tested against a real `sdcard.img` before being trusted, with
`util-linux fdisk` — an independent implementation — as the checker:

```
part3 start sector : 952320
want size sectors  : 6040980  (2949 MB)

Device     Boot  Start     End Sectors  Size Id Type
...img1    *      2048  133119  131072   64M  c W95 FAT32 (LBA)
...img2          133120  952319  819200  400M 83 Linux
...img3          952320 6993299 6040980  2.9G 83 Linux
```

p1 and p2 untouched, p3's start unchanged, and 819200 sectors — exactly
400 MB — left free at the end.

### /data always exists

If the partition cannot be grown, made, checked or mounted, `S03data` mounts a
tmpfs on `/data` instead and logs a warning. Everything downstream is written
against `/data` and needs no fallback logic of its own: the unit boots and
plays music, and the only thing lost is persistence. Losing settings is a bad
day. Refusing to boot is a dead product.

---

## What is persisted, and how

| What | Where | How it was wired |
| --- | --- | --- |
| myMPD settings | `/data/mympd` | `MYMPD_WORKDIR` in `/etc/default/mympd` |
| dropbear host keys | `/data/dropbear` | `/etc/dropbear` is now a symlink there |
| MPD database, state, stickers | `/data/mpd` | `db_file`, `state_file`, `sticker_file` in `mpd.conf` |
| ALSA mixer state | `/data/alsa/asound.state` | `S30alsa` restores from it and now saves to it |

Three of those are worth a note.

**dropbear** needed no script change. Buildroot's `S50dropbear` checks whether
`/etc/dropbear` is a symlink to `/var/run/dropbear` and, if it is, tries to
replace it with a real directory — failing on a read-only root and falling
back to regenerating keys into tmpfs on every boot. Pointing the symlink at
`/data/dropbear` instead makes that check false, so the script leaves it alone
and dropbear writes its keys where they will still be next time. This is the
Phase 4 TODO item about SSH warning on every connection.

**myMPD's cache did not move to `/data`.** The work directory did, but
`MYMPD_CACHEDIR` is now `/tmp/mympd-cache`. Cover art and thumbnails are
regenerable, they are the only thing here that grows without a bound, and
writing them to a CF card continuously is how the card dies. The disk caches
are switched off in `/etc/default/mympd` anyway; this makes sure that turning
one back on cannot quietly start hammering the flash.

**MPD stickers are now on.** `sticker_file` was deliberately absent from
`mpd.conf` because it needs `BR2_PACKAGE_MPD_SQLITE` and had nowhere
persistent to live. Both are now true, and myMPD uses stickers heavily —
ratings, play counts, "loved".

Anything exported in `/etc/default/mympd` still overwrites the persisted
setting on every start. That is myMPD's own behaviour and it is now a useful
distinction rather than a limitation: export a setting to pin it, leave it out
to let the web UI own it.

---

## Network shares

The music is on a NAS, and the obvious route — myMPD's mount dialog, an
`smb://` URI, MPD's smbclient storage plugin — **cannot work on this image**:

```
config BR2_PACKAGE_MPD_LIBSMBCLIENT
	depends on BR2_TOOLCHAIN_USES_GLIBC
	select BR2_PACKAGE_SAMBA4

config BR2_PACKAGE_SAMBA4
	depends on !BR2_TOOLCHAIN_USES_MUSL
```

This image is musl, for size. Getting `smb://` into myMPD's UI would mean
rebuilding every binary against glibc and pulling in samba4, python and gnutls
to serve one mount dialog. So the kernel mounts the share and MPD sees an
ordinary directory. myMPD browses it exactly as it browses a USB stick; the
only thing lost is the *Mounts* page, which would not have worked anyway.

`CONFIG_CIFS=y` is enough — it `select`s its own crypto, keys, ASN.1 and
`NETFS_SUPPORT`. Shares are listed in `/etc/default/shares`, one per line, and
mounted read-only under `/media` by `/etc/init.d/S45shares` at S45, after the
network and before MPD scans.

### Three things the kernel will not tell you

**`credentials=` is silently discarded.** The kernel maps both `credentials=`
and `cred=` to `Opt_ignore` in `fs/smb/client/fs_context.c`, because they are
`mount.cifs` features and this image has no `mount.cifs`. Put them in an option
string and the mount proceeds anonymously and fails with a permission error
that says nothing about the option having been dropped.
`slmp-mount-share` reads `/data/shares/<name>.cred` itself and builds
`user=`/`pass=` from it.

**Credentials live on `/data`, not in the image.** `/data/shares` is created
mode 0700 by `S03data`. That keeps a password out of git, and it means a
reflash does not lose it.

**A password containing a comma cannot be passed at all.** The mount option
string has no escaping and the kernel splits on commas. The script warns; the
fix is a different password. It also strips trailing whitespace from the
username and domain — always a typo there — but deliberately *not* from the
password, where a trailing space could be real.

**Use an IP address.** The kernel has no resolver. `CONFIG_DNS_RESOLVER` is
pulled in by CIFS but its upcall needs a userspace helper this image does not
ship.

---

## USB drives

`/usr/sbin/slmp-usb-mount`, called by mdev, mounting under `/media/<label>`.
`mpd.conf`'s `music_directory` is now `/media`, so each drive appears as a
top-level folder and NFS or SMB shares can mount alongside them later.

### Read-only, on purpose

Every drive is mounted `ro,nosuid,nodev,noexec`. This is an appliance whose
drives get pulled without warning by people with no way to fsck anything. A
read-only mount cannot be corrupted by a yank, needs no journal replay, and
will mount a drive that was itself unplugged uncleanly from a PC. The cost is
that the unit cannot write to a stick, which nothing currently wants to do.

### Filesystems

`CONFIG_EXFAT_FS` and `CONFIG_NTFS3_FS` were added to the kernel fragment —
both in-tree in 6.6, so neither costs an out-of-tree module. With FAT and ext4
already there, that covers what people actually format drives as. `mount` is
called with no `-t`, so the kernel picks; `iocharset=utf8` is tried first and
dropped on a second attempt, because ext4 rejects it and the FAT family wants
it.

### Two things that were not obvious

**The device name comes off an untrusted filesystem.** A volume label is
whatever the person who formatted the drive typed, and it is about to become a
path. It is run through `tr -c 'A-Za-z0-9._-' '_'` and has leading dots
stripped, then falls back to the kernel device name if nothing survives.
Tested:

```
[../../etc]    -> [etc]
[/etc/passwd]  -> [etc_passwd]
[a;rm -rf /]   -> [a_rm_-rf__]
[.....]        -> [sdb1]
[]             -> [sdb1]
```

**mdev never hears about a drive that was already plugged in.** Buildroot's
`S10mdev` starts the netlink daemon with `mdev -df` and coldplugs *modules*,
but it never runs `mdev -s`. A drive present at power-on gets its `/dev` node
from devtmpfs without any uevent for mdev to act on, so the mount rule never
fires. `/etc/init.d/S11usb` calls `slmp-usb-mount scan` once at boot, which
walks `/sys/class/block` and mounts what is already there. It runs at S11, so
after mdev and well before `S95mpd` scans `/media`.

### The mdev rule

```
sd[b-z][1-9][0-9]?	root:root 660 */usr/sbin/slmp-usb-mount
```

`sd[b-z]` only: the CompactFlash card is `sda`, and automounting the disk the
system is running from would be a fine way to lose it. Partitions only, so a
drive with no partition table is left alone. `*` rather than `@` or `$` so the
script runs on both add and remove.

The rule is **appended to Buildroot's `/etc/mdev.conf` by `post-build.sh`**
rather than shipped as a forked copy of the whole file. mdev has no `include`
directive, and Buildroot's version carries the tty, sound and input
permissions we have no reason to own. Appending is safe because mdev stops at
the first matching rule and nothing above it matches a block device; the
append is guarded by a grep because `TARGET_DIR` survives between builds.

---

## Files created

```
board/slmp/mdev-usb.conf                            the mdev rule
board/slmp/rootfs-overlay/etc/init.d/S03data        partition: grow, mkfs, mount
board/slmp/rootfs-overlay/etc/init.d/S11usb         mount drives present at boot
board/slmp/rootfs-overlay/etc/dropbear -> /data/dropbear
board/slmp/rootfs-overlay/usr/sbin/slmp-usb-mount   mount/unmount helper
```

## Files edited

| File | Change |
| --- | --- |
| `board/slmp/genimage.cfg` | p3, 8 MB, no image and no filesystem |
| `board/slmp/rootfs-overlay/etc/fstab` | `/media` tmpfs; `/data` noauto; dropped the myMPD tmpfs |
| `board/slmp/rootfs-overlay/etc/mpd.conf` | `music_directory` `/media`; db, state, playlists, stickers on `/data` |
| `board/slmp/rootfs-overlay/etc/init.d/S30alsa` | restores from `/data`, and now saves on shutdown |
| `board/slmp/rootfs-overlay/etc/default/mympd` | workdir on `/data`, cache on tmpfs |
| `board/slmp/rootfs-overlay/etc/init.d/S96mympd` | matching defaults |
| `board/slmp/post-build.sh` | appends the mdev rule |
| `board/slmp/linux.fragment` | `EXFAT_FS`, `NTFS3_FS`, `NLS_UTF8` |
| `board/slmp/busybox.fragment` | a comment recording a symbol that cannot be set |
| `configs/slmp_defconfig` | `E2FSPROGS`, `MPD_SQLITE` |
| `br2-external/package/mympd/mympd.mk` | dropped the now-unused `/var/lib/mympd` hook |

### The busybox symbol that could not be set

`CONFIG_FDISK_SUPPORT_LARGE_DISKS` looks like it is needed — `fdisk` is on and
the option is literally named "Support over 4GB disks", which is the size of
card this product shipped with. Adding it to `busybox.fragment` and rebuilding
showed it still `not set` afterwards, which is the silent drop the validation
in `phase 1.sh` exists to catch. The reason is in the busybox source:

```
//config:	depends on !LFS   # with LFS no special code is needed
```

Buildroot sets `CONFIG_LFS=y`, so the symbol is unavailable and fdisk already
handles large disks. The fragment now carries the explanation instead of the
symbol.

---

## Init order

```
S03data   mount /data, or a tmpfs if that fails
S10mdev   hotplug daemon (Buildroot's)
S11usb    mount USB drives already present
S30alsa   restore mixer state from /data
S40network
S50dropbear   host keys from /data
S95mpd    database and stickers on /data, scans /media
S96mympd  settings on /data
```

Shutdown runs the reverse, which matters in one place: `S30alsa` saves the
mixer state before `S03data` unmounts the partition it saves to.

---

## Commands

```bash
git submodule update --init --recursive
./phase\ 1.sh
```

On the unit:

```bash
df -h /data                    # 2.9G on a 4 GB card, 16M if it fell back to tmpfs
grep data /var/log/messages    # what S03data decided and why
mount | grep -E '/data|/media'
ls /media                      # one directory per USB drive
slmp-usb-mount scan            # re-scan by hand
fdisk -l /dev/sda              # p3 should end 400 MB short of the card
```

---

## What the first hardware run found

The Phase 2 image was flashed to a BDP-1 and booted. Findings, in order of how
much they mattered.

### The storage work did what it was supposed to

The partition grew, the reboot happened, and the filesystem was created:

```
Device     Boot StartLBA     EndLBA    Sectors  Size Id Type
/dev/sda1  *        2048     133119     131072 64.0M  c Win95 FAT32 (LBA)
/dev/sda2           133120    952319     819200  400M 83 Linux
/dev/sda3           952320   7028079    6075760 2966M 83 Linux

/dev/sda3: LABEL="SLMPDATA" UUID="4b974f2e-ab90-40fb-9d15-279efe938645"
```

The card reports 7847280 sectors. p3 ends at 7028079, leaving 819200 sectors —
exactly the 400 MB reserved for the Phase 4 B slot. The hand-written
partition-table field, the reboot to make the kernel re-read it, and `mke2fs`
all worked on the first try on real hardware. Mounted by hand, the filesystem
is clean and shows 2.8 GB available.

### And then nothing could be mounted on it

```
data: no filesystem on /dev/sda3, creating one
data: mount of /dev/sda3 failed; falling back to tmpfs
data: WARNING: /data is a tmpfs. Settings will not survive a reboot.
```

`/data` was not a tmpfs. `/data` was not mounted at all:

```
# ls -ld /data
ls: /data: No such file or directory
# mkdir -p /data
mkdir: can't create directory '/data': Read-only file system
```

**The mountpoint was never created in the image.** `S03data` opens with
`mkdir -p "$DATA_DIR"`, which cannot work on a read-only root, so every mount
onto `/data` failed — the ext4, and then the tmpfs fallback that exists
precisely to keep the unit working when the partition is unusable. Buildroot's
skeleton provides `/media`, which is why that tmpfs mounted fine, and does not
provide `/data`.

The fix is one line in `post-build.sh`:

```sh
install -d -m 0755 "$TARGET_DIR/data"
```

`/var/lib/mympd` used to be created by a hook in `mympd.mk`. That hook was
deleted when the work directory moved to `/data`, and nothing replaced it.

### Which took both daemons down with it

MPD writes its database under `/data` and myMPD its work directory, so neither
could start. myMPD says so precisely, when run by hand:

```
NOTICE   mympd      Cache dir: "/tmp/mympd-cache"
ERROR    mympd      Work dir: creating "/data/mympd" failed
ERROR    mympd      No such file or directory
```

MPD left no log at all, because `log_file` is on the filesystem it could not
reach.

Running `mympd` by hand made this more confusing rather than less: with no
arguments it uses its compiled-in `/var/lib/mympd`, not the `/data/mympd` the
service is told to use, so the errors pointed at a path nothing was configured
to write to. `/var/lib/mympd` is now a symlink to `/data/mympd`, so both routes
lead to the same place. The details are in
[mympd.md](mympd.md#decisions-and-limitations).

And `/var/lib/mympd` was present on the unit as a real directory, months after
the hook that created it had been deleted from `mympd.mk` — Buildroot does not
remove files from `output/target` when a package stops installing them, so it
had been baked into every image since. Harmless here, but it means an
incremental build and a clean build of the same tree are not necessarily the
same image.

### The log was lying

Worth its own note, because it cost time. `fallback()` ran
`mount -t tmpfs ... 2>/dev/null` and then logged "WARNING: /data is a tmpfs"
**unconditionally**, so the log confidently described a state that did not
exist. It now reports what happened rather than what was attempted, and says
what to check:

```
data: ERROR: nothing could be mounted on /data.
data: ERROR: does the directory exist in the image? MPD and myMPD will not start.
```

A fallback path that cannot fail loudly is not a fallback path.

---

## Verifying the fix without reflashing

The rebuilt image contains `/data`. To confirm the rest of the chain on a unit
that is already running the broken build, create the directory by hand and
start the services — the partition and its filesystem are already correct:

```bash
mount -o remount,rw / && mkdir -p /data && mount -o remount,ro /
/etc/init.d/S03data start
/etc/init.d/S95mpd start
/etc/init.d/S96mympd start
df -h /data && mpc status && wget -qO- http://127.0.0.1/ | head -c 80
```

If that brings the web UI up, the only thing the reflash adds is the
mountpoint.

---

## Confirmed working on hardware

After the mountpoint fix, on a BDP-1 at 2.9 GB of data partition:

```
/dev/sda3 on /data type ext4 (rw,noatime)
/dev/sda3   2.8G   1.2M   2.8G   0% /data

/data/mpd/database          MPD's tag database, no longer rebuilt every boot
/data/mympd/config          myMPD's settings, one file per setting
/data/alsa  /data/dropbear  waiting for a mixer save and a first ssh connection
```

`mpc status` answers, myMPD logs `Connected to MPD` and serves its embedded UI
on port 80, and the whole unit sits at 9 MB of 228 MB used. The grow, the
reboot, `mke2fs`, the mount and every redirection into `/data` all work.

`/data/dropbear` is empty so far, which is correct rather than broken:
Buildroot's `S50dropbear` passes `-R`, so host keys are generated on the first
SSH connection rather than at boot. Whether they then survive a reboot is the
one persistence claim still unverified.

---

## What is still untested

- **Playback.** Nothing has produced sound. ALSA sees the Juli@ as card 0 with
  IEC958 on device 1, which is what `mpd.conf` already assumed, but that is a
  long way from audio out of the coax socket.
- **myMPD's first scan of a real library**, and what it costs on a 500 MHz CPU.
  The UI itself serves in 15 ms with an empty database.
- **dropbear host key persistence across a reboot.** The directory is there on
  `/data` with the right mode, but `-R` means no key exists until the first SSH
  connection, so nothing has been carried across a reboot yet.
- **USB automount.** No drive has been plugged into a real unit, so neither the
  mdev rule, the boot-time scan, exfat nor ntfs3 has run once.
- **A second first-boot.** The grow-and-reboot worked, but it has happened once
  on one card. The path where the card is too small to grow into has never run.
