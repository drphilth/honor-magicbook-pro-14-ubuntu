# Step 0 — build the HONOR MagicBook Pro 14 install ISO

The stock Ubuntu installer **won't boot usefully** on this laptop: the OEM DSDT has a load-time
abort that hides the NVMe drive and breaks the touchpad. So before installing, remaster the Ubuntu
ISO to carry the corrected DSDT (and a clean touchscreen). This is a one-command, fully reversible
step — your current install is untouched, and you can rebuild/boot test ISOs freely.

## Build it

```bash
# 1. get a stock Ubuntu desktop ISO (26.04 = kernel 7.0, matches the target)
#    https://releases.ubuntu.com/26.04/ubuntu-26.04-desktop-amd64.iso

# 2. one command -> a MagicBook install ISO
iso/build-install-iso.sh  ubuntu-26.04-desktop-amd64.iso  ubuntu-26.04-MB.iso
```

`build-install-iso.sh` regenerates everything from sources in this repo and bakes in:

1. **DSDT fix** — `honor-fmbp/dsdt/dsdt.global.aml` packed as a kernel **initrd ACPI override**
   (`kernel/firmware/acpi/dsdt.aml`, `CONFIG_ACPI_TABLE_UPGRADE`) and prepended to the casper
   `initrd` line in **both** `grub.cfg` and `loopback.cfg` (Ventoy may use either). Fixes the
   boot-critical NVMe/touchpad abort and powers the touchscreen.
2. **Touchscreen udev rule** — injected into the live squashfs layer
   (`minimal.standard.live.squashfs`) so the live/installer session's touchscreen doesn't spam
   `KEY_MICMUTE`.

Needs `xorriso`, `squashfs-tools`, `cpio`; uses `sudo` internally for the squashfs surgery (run it
as your normal user — the output ISO stays user-owned).

### Build host

Runs on any Linux (no loop-mounting or kernel modules — it's just `xorriso` + `squashfs-tools`
repacking files), including inside a container or VM. Two non-Linux notes:

- **Windows (WSL):** use **WSL2, not WSL1**. Run the build inside your WSL **home directory** (or
  `/tmp`) — **not** under `/mnt/c`. The rebuilt live layer must preserve Linux ownership, xattrs and
  symlinks, which the Windows drive mount (`/mnt/c`) silently drops, corrupting the squashfs. WSL1's
  filesystem translation breaks this even in `~`. Install deps with
  `sudo apt install xorriso squashfs-tools cpio dpkg-dev`. Writing the finished ISO to a USB/Ventoy
  stick is done from Windows afterwards (WSL can't access raw USB devices).
- **macOS:** not natively — it needs GNU userland (`numfmt`, GNU `stat`/`cpio`, …) and, more
  fundamentally, macOS can't faithfully round-trip a Linux root filesystem (device nodes, security
  capabilities, and APFS being case-insensitive by default → filename collisions). Build it in a
  Linux **container or VM** instead (Docker Desktop, Colima/Lima, UTM, …). Because the build only
  *repacks* files and never executes the target's amd64 binaries, an **Apple-Silicon (arm64)**
  container/VM still produces a valid amd64 ISO.

## Boot it (Ventoy)

1. Copy the output ISO onto a **Ventoy** stick. **Wait for the write to fully flush / eject
   safely** before unplugging — a truncated copy shows "press any key → back to Ventoy menu".
2. Boot the stick, pick the ISO. At the GRUB menu the entries are tagged **`[MB-initrd]`** — that's
   the tell-tale our config is active. Choose **Try or Install Ubuntu**.

Ventoy notes for this machine (learned the hard way): `conf_replace` does **not** work here — the
remastered ISO is self-contained, so plain Ventoy boot is enough. Both `grub.cfg` and `loopback.cfg`
are patched, so normal and loopback boot paths both apply the override.

## Confirm it worked

No forensics needed — the DSDT carries both fixes, so:

> **If it boots, the touchpad moves the cursor, and the touchscreen responds to touch (without
> toggling the mic), the override is working.**

## Install Ubuntu, then bake the DSDT in before the first reboot

The ISO gets you a **bootable installer** with working input. But the **installed** system needs the
corrected DSDT baked into *its* own initramfs before it boots the first time — the stock DSDT hides
the NVMe root, so without this the first boot hangs. So:

1. Run the Ubuntu installer as normal. **When it finishes, do _not_ click "Restart now"** — instead
   close/quit back to the live desktop and open a terminal.
2. Run the bundled offline install helper. The live session mounts the ISO read-only —
   usually at `/media/cdrom` (on some boots `/cdrom`):

   ```bash
   sudo /media/cdrom/honor-fmbp/honor-fmbp-install.sh
   # if that path doesn't exist, locate the helper:
   #   ls -d /media/*/honor-fmbp /media/cdrom/honor-fmbp /cdrom/honor-fmbp 2>/dev/null
   ```

   It finds the freshly-installed system, chroots it, and installs — **entirely offline, from a deb
   repo baked on this ISO** — the boot-critical `honor-fmbp-dsdt` (which bakes the DSDT into the
   installed initramfs), the input/power quirks
   (`honor-fmbp-config`), and the PPA apt source (`honor-fmbp-archive-keyring`). It verifies the DSDT
   actually landed in the installed initramfs before telling you it's safe to reboot.

   It asks which **DSDT variant** to install: the live session runs the global table, so
   the firmware's variant can't be detected from here. Keep the default, **global**, unless
   you know the firmware is the Chinese variant (GNVS at `0x67E19018`). The variant is not
   the sales region: units bought in China have needed the global table
   ([colorcube#15](https://github.com/colorcube/Linux-on-Honor-Magicbook-14-Pro/issues/15)).
   A Chinese answer is pinned in `/etc/honor-fmbp/dsdt-force` on the installed system. Non-interactive: `sudo SKU=chinese ASSUME_YES=1 …/honor-fmbp-install.sh`.
   *(If the installer already unmounted things, pass the root explicitly, e.g.
   `sudo mount /dev/nvme0n1p2 /mnt && sudo /media/cdrom/honor-fmbp/honor-fmbp-install.sh /mnt`.)*
3. Reboot into the installed system — NVMe, touchpad and touchscreen work from boot #1.
4. Finish the rest **online** (DKMS fan/keyboard drivers, fingerprint, SOF audio firmware — these
   build against the running kernel and need MOK enrollment, so they belong on the booted system):

   ```bash
   sudo apt update && sudo apt install honor-magicbook-pro-14
   ```

   The PPA was already configured offline in step 2, so this pulls from `ppa:drphilth/honor-fmbp`.

> **Note (ISO builders):** the `/honor-fmbp` helper + repo are only baked in if `build-install-iso.sh`
> finds built debs at the repo root (or `$DEB_DIR`). A `honor-fmbp-archive-keyring` deb only exists
> once the PPA's signing key has been fetched (`honor-fmbp/keyring/fetch-ppa-key.sh`, post first-publish); before
> that the ISO still works but step 2 configures no PPA and step 4 needs the PPA added by hand.
