# HONOR MagicBook Pro 14 (2025) — Ubuntu

Ubuntu enablement for the **HONOR MagicBook Pro 14 2025 (FMB-P)** — Intel Core Ultra
(Arrow Lake-H). Everything installs as Debian packages from a Launchpad PPA:

```bash
sudo add-apt-repository ppa:drphilth/honor-fmbp
sudo apt install honor-magicbook-pro-14
```

> **`apt update` fails with "Conflicting values set for option Signed-By"?** Packages
> up to 1.0.5 left the PPA configured twice (once by `add-apt-repository`, once by
> `honor-fmbp-archive-keyring`). Remove the `add-apt-repository` copy — the package's
> own `honor-fmbp.sources` stays and covers the same repository:
>
> ```bash
> sudo rm /etc/apt/sources.list.d/drphilth-ubuntu-honor-fmbp-*
> sudo apt update
> ```
>
> From 1.0.6 the package removes that copy itself on install. Don't re-run
> `add-apt-repository` for this PPA once the package is installed.

Out of the box this laptop **cannot even boot an installer usefully**: a load-time abort
in the OEM ACPI DSDT hides the NVMe drive and kills the touchpad. This repo ships the
corrected DSDT plus everything else the hardware needs, packaged so it stays applied
across kernel and BIOS-unrelated updates.

> **Target release: Ubuntu 26.04 (resolute), kernel 7.0.** Earlier releases are untested.
> **Secure Boot off is the simplest supported configuration** (firmware: F2 → set a
> supervisor password if asked → Secure Boot → Disabled). Secure Boot *can* be kept on,
> with caveats — see [Secure Boot](#secure-boot) below.

## What works

With these packages, effectively everything:

| Component | State |
|---|---|
| NVMe visibility, touchpad, USB-C (incl. DisplayPort) | ✅ fixed by the corrected DSDT (boot-critical) |
| Touchscreen (FocalTech FTSC1000) | ✅ fixed in the same DSDT (ACPI `PowerResource` injection) + udev quirk |
| Display / Intel Arc graphics / HDR, WiFi 6E, Bluetooth, webcam, suspend/resume | ✅ native |
| Audio (Intel cAVS / SOF) | ✅ Intel SOF firmware (`firmware-sof-signed` — standard on Ubuntu; the metapackage guarantees it) |
| Fan RPM readout (`sensors`) | ✅ `honor-fmbp-hwmon-dkms` (custom EC driver) |
| Keyboard backlight (GNOME Quick Settings, off/low/high) | ✅ `honor-fmbp-kbdlight-dkms` (custom EC driver; re-login once after install) |
| Battery charge-limit presets (40–70 / 70–90 / 95–100) | ✅ `honor-fmbp-config` (huawei-wmi + restore unit; BIOS ≥ 1.16) |
| Fn keys, LEDs, keyboard quirks | ✅ native on kernel 7.0 + a small hwdb fix |
| Fingerprint (EgisTec ET171, SDCP/Windows-Hello match-on-chip) | ✅ [`honor-fmbp-libfprint-sdcp`](https://github.com/drphilth/honor-fmbp-libfprint-sdcp) (pulled in via Recommends) |

## Installing

### Fresh install (recommended path)

The stock Ubuntu ISO won't cut it (no NVMe, no touchpad), so step 0 is remastering it —
one command, then a normal install with one extra step before the first reboot.
**Follow [`iso/install-iso.md`](iso/install-iso.md).** In short:

1. `iso/build-install-iso.sh stock-ubuntu-26.04.iso out.iso` → bootable installer with
   working input and NVMe.
2. Install Ubuntu normally; **before rebooting**, run the bundled offline helper
   (`sudo /media/cdrom/honor-fmbp/honor-fmbp-install.sh`) — it bakes the DSDT into the
   *installed* system's initramfs and pre-configures the PPA, entirely offline.
3. Reboot, then `sudo apt install honor-magicbook-pro-14` for the rest (DKMS drivers,
   fingerprint, audio firmware).

### Existing install

If you already have Ubuntu running on this machine (i.e. you applied some DSDT
workaround yourself, typically a GRUB ACPI override), just add the PPA and install the
metapackage as at the top. `honor-fmbp-dsdt` detects your BIOS SKU and bakes the
corrected table into the initramfs (initramfs-tools and dracut both supported) — after
verifying a reboot, you can retire your hand-rolled override.

## Packages

One source package (`honor-fmbp`, in [`honor-fmbp/`](honor-fmbp/)) builds:

| Package | Contents |
|---|---|
| `honor-magicbook-pro-14` | metapackage — everything below + `acpi-call-dkms`, `firmware-sof-signed`, `libpam-fprintd` |
| `honor-fmbp-dsdt` | corrected DSDT (both SKUs), GNVS SKU auto-detect, initramfs-tools/dracut early-ACPI override |
| `honor-fmbp-config` | input/device quirks (udev + hwdb), touchscreen toggle, battery-threshold unit + presets, battery-extension dconf defaults |
| `honor-fmbp-hwmon-dkms` | fan-RPM hwmon driver (EC, reverse-engineered) |
| `honor-fmbp-kbdlight-dkms` | keyboard-backlight LED driver (EC `KBBL`; native GNOME/KDE control) |
| `honor-fmbp-archive-keyring` | the PPA's apt source + signing key (lets the offline installer "add the PPA" with no network) |

Build locally with `cd honor-fmbp && dpkg-buildpackage -us -uc -b` (needs
`debhelper`, `dh-dkms`).

## The DSDT fix

The OEM DSDT runs a `GNUM` call at table-load time from the NFC device that aborts the
entire table — the kernel falls back to a crippled namespace (no NVMe, no touchpad). The
fix removes that one call, injects an ACPI `PowerResource` so the touchscreen panel gets
powered (the OEM only wrote one for disabled sibling panels), and bumps the OEM revision
so the kernel accepts the override. Full mechanism analysis:
[`docs/dsdt-root-cause.md`](docs/dsdt-root-cause.md); reproducible build pipeline (from
your own firmware dump): [`dsdt/`](dsdt/).

**Two BIOS SKUs exist** (global / Chinese), identical except for six NVS base addresses;
`honor-fmbp-dsdt` ships both tables and auto-detects yours at install time.
The **global** variant is hardware-tested (this project's reference unit). The
**Chinese** variant is built through the same pipeline but **unverified on real
hardware** — if you own a Chinese-SKU unit, please test and report back in an issue.

## Secure Boot

**Recommended: turn Secure Boot off.** It's the simplest, most robust configuration and
what the install guide assumes. With it off, the DSDT override applies and the DKMS
drivers load, no key management required.

Secure Boot can be kept **on**, but understand the two moving parts — they behave
differently and were verified on 26.04's kernel 7.0.0-27:

- **The DSDT override.** On kernel 7.0 the initrd ACPI-table override still applies with
  Secure Boot on — confirmed on hardware (`dmesg`: `Kernel is locked down from EFI Secure
  Boot mode` *and* `ACPI: Table Upgrade: override [DSDT- HONOR- ARL]`, our rev-3 table
  live). This works because of a boot-ordering detail in 7.0's `start_kernel()`
  (`setup_arch()` runs before the lockdown LSM's hook is armed, so the
  `LOCKDOWN_ACPI_TABLES` check that *would* reject the override is not yet active when
  `acpi_table_upgrade()` runs). **This is not guaranteed across kernel updates** — it reads
  like an unintended gap, and a future kernel could reinstate the check, at which point the
  override would be silently ignored and the machine would fail to boot (no NVMe). Do not
  rely on it for an unattended box. There is no signed-DSDT mechanism in the kernel, so MOK
  enrollment cannot bless the override — this ordering quirk is the only reason it currently
  works under Secure Boot.
- **The DKMS drivers** (`honor-fmbp-hwmon`, `honor-fmbp-kbdlight`). These *are* subject to
  normal module-signature enforcement and are **rejected under Secure Boot until their
  signing key is enrolled** (`modprobe … → Key was rejected by service`). DKMS already
  signs them at build time with the machine-local MOK at `/var/lib/shim-signed/mok/MOK.der`
  (via `dkms` + `shim-signed`). Enroll that key once:

  ```bash
  sudo mokutil --import /var/lib/shim-signed/mok/MOK.der   # sets a one-time password
  sudo reboot                                              # MokManager → Enroll MOK → same password
  ```

  After enrollment the drivers load normally with Secure Boot on. (Under Secure Boot off,
  no enrollment is needed — unsigned local modules load fine.)

## Repo layout

```
honor-fmbp/   the Debian source package (everything apt-installable)
iso/          step-0 install-ISO builder + offline pre-first-boot helper
dsdt/         the pipeline that produced the shipped DSDTs (transparency / future BIOSes)
docs/         root-cause analysis of the DSDT defect
```

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for the version history (per-package detail in
[`honor-fmbp/debian/changelog`](honor-fmbp/debian/changelog)).

## Credits

- **denis-bb**'s `honor-fmb-p-dsdt` — the first public FMB-P DSDT workaround and the
  reference material for the Chinese-SKU cross-check (`dsdt/reference/fetch.sh`).
- **EvernightFedora**'s FMB-P Fedora work — independent cross-check of the hardware
  matrix and the first ET171 fingerprint enablement.
- The **libfprint** project — the fingerprint package tracks upstream's SDCP branch
  (merge request 547).

## License

GPL-2 (see [`LICENSE`](LICENSE)), except the two shipped DSDT tables, which are
minimally-patched derivatives of HONOR's firmware ACPI table, redistributed to owners of
the covered hardware as an interoperability fix — see
[`honor-fmbp/debian/copyright`](honor-fmbp/debian/copyright) for the exact statement.
