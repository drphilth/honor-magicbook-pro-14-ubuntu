# Changelog

User-facing history of the `honor-fmbp` packages (installed via
`ppa:drphilth/honor-fmbp` / `apt install honor-magicbook-pro-14`). The
authoritative, per-package detail lives in
[`honor-fmbp/debian/changelog`](honor-fmbp/debian/changelog); this file is the
readable summary.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [1.0.5] — 2026-07-11

### Fixed
- **Fan RPM sensors and the GNOME keyboard-backlight control now work on a clean
  boot.** The `honor-fmbp-hwmon` and `honor-fmbp-kbdlight` kernel modules have no
  device modalias, so nothing was loading them automatically — on a fresh install
  the fan sensors and backlight control were silently absent until a manual
  `modprobe`. Each DKMS package now ships a `modules-load.d` drop-in so the driver
  loads at every boot.

### Documentation
- Battery Health Charging extension setup now documents the **enable** step (a
  reinstall or home restore can leave it installed but disabled).

## [1.0.4] — 2026-07-07

### Fixed
- **`honor-fmbp-dsdt` now supports both dracut and initramfs-tools** and no longer
  forces a generator swap. Ubuntu 26.04 defaults to dracut; the old
  `Depends: initramfs-tools` pulled initramfs-tools over the network and removed
  dracut on a fresh install, breaking the offline pre-first-boot DSDT bake. The
  boot-critical DSDT override is now applied by whichever generator is present.

## [1.0.3] — 2026-07-04

### Added
- **`honor-fmbp-archive-keyring`** — adds the PPA (deb822 `.sources` + signing key)
  purely by dropping files, so it can be applied from the installer chroot with no
  network. The metapackage depends on it.

### Changed
- Clarified that Intel SOF audio firmware comes from the Ubuntu archive
  (`firmware-sof-signed`), not from this package.

## [1.0.2] — 2026-07-03

### Added
- **Dual-SKU DSDT support.** Ships the corrected DSDT for both the global and
  Chinese FMB-P BIOS variants and auto-selects the right one at install by matching
  the live firmware's GNVS signature. Override with `/etc/honor-fmbp/dsdt-force`.
  (The Chinese AML is derived from the same fixes but is **untested on real Chinese
  hardware** — see `README.Debian`.)
- **Battery charge-limit preset** restored at boot via
  `honor-battery-thresholds.service`, configurable in `/etc/default/honor-fmbp-battery`
  (default 70–90%).
- Pre-seeded correct presets for the maniacx "Battery Health Charging" GNOME
  extension so its Quick Settings panel matches what the firmware enforces.
- Metapackage `Recommends: gnome-shell-extension-manager`.

## [1.0.1] — 2026-07-03

### Fixed
- Restored per-package payload wiring accidentally dropped in 1.0.0, which had
  produced empty (docs-only) packages whose reinstall removed the DSDT override and
  DKMS sources — leaving an unbootable system with no NVMe. The build now fails
  unless every payload file is present, so an empty package can never ship silently.

## [1.0.0] — 2026-07-02

### Added
- Initial packaging: `honor-fmbp-hwmon` + `honor-fmbp-kbdlight` DKMS modules, the
  corrected DSDT as an initramfs early ACPI override, udev/hwdb input quirks, and the
  `honor-magicbook-pro-14` metapackage.

[1.0.5]: https://github.com/drphilth/honor-magicbook-pro-14-ubuntu/commits/main
[1.0.4]: https://github.com/drphilth/honor-magicbook-pro-14-ubuntu/commits/main
[1.0.3]: https://github.com/drphilth/honor-magicbook-pro-14-ubuntu/commits/main
[1.0.2]: https://github.com/drphilth/honor-magicbook-pro-14-ubuntu/commits/main
[1.0.1]: https://github.com/drphilth/honor-magicbook-pro-14-ubuntu/commits/main
[1.0.0]: https://github.com/drphilth/honor-magicbook-pro-14-ubuntu/commits/main
