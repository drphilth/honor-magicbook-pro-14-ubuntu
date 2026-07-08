#!/usr/bin/env bash
# build-install-iso.sh — TURNKEY: turn a stock Ubuntu desktop ISO into a HONOR MagicBook
# Pro 14 (FMB-P) install ISO, regenerating everything from sources in THIS repo:
#
#   (a) DSDT fix  -> corrected dsdt.aml packed as a kernel initrd ACPI override
#                    (CONFIG_ACPI_TABLE_UPGRADE), prepended to the casper initrd line.
#                    Fixes the boot-critical NFC0 abort (touchpad + NVMe) AND powers the
#                    touchscreen. Applied via grub.cfg AND loopback.cfg (Ventoy uses either).
#   (b) touchscreen udev rule -> injected into the live squashfs layer so the live/installer
#                    session's touchscreen doesn't spam KEY_MICMUTE.
#   (c) offline install helper + local deb repo -> grafted onto the ISO at /honor-fmbp, so
#                    the INSTALLED system's DSDT can be baked in before first boot with no
#                    network (see honor-fmbp-install.sh). Only added if built debs are found.
#
# (a)+(b) make the installer bootable/usable; (c) carries the honor-fmbp packages so the
# installed system boots on the first try. The DKMS drivers, fingerprint and audio firmware
# still go in online after first boot (apt install honor-magicbook-pro-14).
#
#   sudo ./build-install-iso.sh <stock-ubuntu-desktop.iso> [output.iso]
#   DEB_DIR=/path/to/debs sudo -E ./build-install-iso.sh <stock.iso> [out.iso]   # override repo src
#
# output.iso is optional; it defaults to <stock-basename>-MB-initrd.iso in the CURRENT
# directory. Needs: xorriso, squashfs-tools, cpio (and dpkg-dev if bundling debs). Uses sudo
# internally for the squashfs surgery, so run it as your normal user (the ISO stays user-owned).
set -euo pipefail

IN="${1:?usage: build-install-iso.sh <stock-ubuntu.iso> [output.iso]}"
OUT="${2:-$PWD/$(basename "$IN" .iso)-MB-initrd.iso}"
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
AML="$repo/honor-fmbp/dsdt/dsdt.global.aml"
RULE="$repo/honor-fmbp/config/udev/rules.d/99-honor-fmbp-touchscreen.rules"
DEB_DIR="${DEB_DIR:-$repo}"                           # where prebuilt honor-fmbp debs live
LIVE_LAYER="/casper/minimal.standard.live.squashfs"   # Ubuntu desktop 24.04+ layered squashfs

for f in "$IN" "$AML" "$RULE"; do [ -r "$f" ] || { echo "missing: $f"; exit 1; }; done
for t in xorriso unsquashfs mksquashfs cpio; do command -v "$t" >/dev/null || { echo "need $t"; exit 1; }; done

work="$(mktemp -d)"; trap 'sudo rm -rf "$work"' EXIT

echo "== [1/4] build ACPI override cpio from $(basename "$AML") =="
# OEM revision sanity: must exceed the firmware's (0x02) or the override is ignored.
rev=$(od -An -tu4 -j24 -N4 "$AML" | tr -d ' ')
echo "   dsdt.aml OEMRevision = $rev  (firmware = 2; must be higher)"
[ "${rev:-0}" -gt 2 ] || { echo "!! dsdt.aml OEMRevision is not > 2 — override would be ignored"; exit 1; }
mkdir -p "$work/ov/kernel/firmware/acpi"
cp "$AML" "$work/ov/kernel/firmware/acpi/dsdt.aml"
( cd "$work/ov" && find kernel | cpio -H newc --create --quiet ) > "$work/acpi_override.img"
echo "   -> $work/acpi_override.img ($(stat -c%s "$work/acpi_override.img" | numfmt --to=iec))"

echo "== [2/4] inject touchscreen udev rule into the live layer ($LIVE_LAYER) =="
xorriso -osirrox on -indev "$IN" -extract "$LIVE_LAYER" "$work/live.squashfs" >/dev/null 2>&1 \
  || { echo "!! $LIVE_LAYER not found in $IN — is this an Ubuntu desktop ISO?"; exit 1; }
comp=$(unsquashfs -s "$work/live.squashfs" 2>/dev/null | awk -F': *' '/Compression/{print $2}')
blk=$(unsquashfs -s "$work/live.squashfs" 2>/dev/null | awk '/Block size/{print $NF}')
echo "   live layer: comp=$comp block=$blk"
sudo unsquashfs -d "$work/live-root" "$work/live.squashfs" >/dev/null 2>&1
sudo install -D -o root -g root -m 0644 "$RULE" \
  "$work/live-root/etc/udev/rules.d/$(basename "$RULE")"
sudo test -f "$work/live-root/etc/udev/rules.d/$(basename "$RULE")" \
  || { echo "!! rule not staged in live-root"; exit 1; }
sudo mksquashfs "$work/live-root" "$work/live-new.squashfs" \
  -comp "${comp:-xz}" -b "${blk:-131072}" -Xbcj x86 -noappend -no-recovery \
  -processors "$(nproc)" > "$work/mksq.log" 2>&1 \
  || { echo "!! mksquashfs FAILED:"; tail -8 "$work/mksq.log"; exit 1; }
sudo chown "$(id -u):$(id -g)" "$work/live-new.squashfs"
# NB: verify via a file, not `unsquashfs -l | grep -q` — grep -q closes the pipe on first
# match and SIGPIPE-kills unsquashfs mid-listing, which makes the check flaky/false-negative.
unsquashfs -l "$work/live-new.squashfs" > "$work/ls.txt" 2>/dev/null
grep -q -- "$(basename "$RULE")" "$work/ls.txt" \
  && echo "   -> rule baked into rebuilt live layer ($(stat -c%s "$work/live-new.squashfs" | numfmt --to=iec))" \
  || { echo "!! rule missing from rebuilt layer"; exit 1; }

echo "== [3/4] stage offline install helper + local deb repo (from $DEB_DIR) =="
extra=""
present=()
for d in "$DEB_DIR"/honor-fmbp*_*.deb "$DEB_DIR"/honor-magicbook-pro-14_*.deb; do
  [ -e "$d" ] && present+=("$d")
done
if [ "${#present[@]}" -gt 0 ]; then
  command -v dpkg-scanpackages >/dev/null || { echo "!! need dpkg-scanpackages (apt install dpkg-dev)"; exit 1; }
  extra="$work/honor-fmbp"
  mkdir -p "$extra/repo"
  cp "${present[@]}" "$extra/repo/"
  install -m 0755 "$here/honor-fmbp-install.sh" "$extra/honor-fmbp-install.sh"
  ( cd "$extra/repo" && dpkg-scanpackages -m . > Packages 2>/dev/null && gzip -9kf Packages )
  ls "$extra/repo"/honor-fmbp-dsdt_*.deb >/dev/null 2>&1 \
    || { echo "!! no honor-fmbp-dsdt deb in $DEB_DIR — build the packages first (boot-critical)"; exit 1; }
  echo "   staged $(ls "$extra/repo"/*.deb | wc -l) deb(s) + honor-fmbp-install.sh -> /honor-fmbp"
else
  echo "   no honor-fmbp debs in $DEB_DIR — building an INSTALLER-ONLY ISO (no baked install)."
  echo "   Build the packages (cd honor-fmbp && dpkg-buildpackage -us -uc -b) or set DEB_DIR."
fi

echo "== [4/4] remaster the ISO (DSDT override + both grub configs + live layer${extra:+ + /honor-fmbp}) =="
"$here/remaster-iso-initrd.sh" "$IN" "$work/acpi_override.img" "$OUT" "$work/live-new.squashfs" "$extra"

echo
echo "✅ turnkey build complete -> $OUT"
echo "   Copy to a Ventoy stick, boot it, pick the [MB-initrd] entry -> Try Ubuntu."
echo "   Pass: touchpad + touchscreen work, and touching the screen doesn't toggle the mic."
