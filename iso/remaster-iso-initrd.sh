#!/usr/bin/env bash
# remaster-iso-initrd.sh — bake the corrected DSDT into a live ISO via the KERNEL INITRD
# ACPI override (CONFIG_ACPI_TABLE_UPGRADE), NOT GRUB's `acpi` command.
#
# This is the same mechanism the honor-fmbp-dsdt package uses on installed systems: an
# uncompressed early cpio (kernel/firmware/acpi/dsdt.aml) prepended to the initrd line. The
# kernel applies it in acpi_table_upgrade() before it ever parses the DSDT, so it's as early
# as GRUB-acpi and fixes the boot-critical NFC0 abort (touchpad + NVMe) the same way.
#
#   ./remaster-iso-initrd.sh <input.iso> <acpi_override.img> <output.iso>
#
# Normally driven by build-install-iso.sh, which builds acpi_override.img for you (step 1).
# Needs: xorriso. Boot the output ISO in Ventoy grub2 mode.
# Ref: https://docs.kernel.org/admin-guide/acpi/initrd_table_override.html
set -euo pipefail
IN="${1:?input iso}"; IMG="${2:?acpi_override.img}"; OUT="${3:?output iso}"
# Optional 4th arg: a replacement /casper/minimal.standard.live.squashfs (e.g. one with our
# touchscreen udev rule injected). Omit to leave the live layer untouched.
LIVE="${4:-}"
# Optional 5th arg: a directory grafted onto the ISO root as /honor-fmbp (the offline
# install helper + local deb repo). Omit to leave the ISO's file tree untouched.
EXTRA="${5:-}"
[ -r "$IN" ]  || { echo "no such input iso: $IN"; exit 1; }
[ -r "$IMG" ] || { echo "no such override img: $IMG"; exit 1; }
[ -z "$LIVE" ]  || [ -r "$LIVE" ] || { echo "no such live squashfs: $LIVE"; exit 1; }
[ -z "$EXTRA" ] || [ -d "$EXTRA" ] || { echo "no such extra dir: $EXTRA"; exit 1; }
command -v xorriso >/dev/null || { echo "need xorriso (apt install xorriso)"; exit 1; }
# xorriso refuses to write to a non-blank -outdev; start clean.
[ -e "$OUT" ] && { echo ">> removing existing output $OUT"; rm -f "$OUT"; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# sanity: the override must be an uncompressed cpio carrying kernel/firmware/acpi/*.aml
if ! cpio -itv < "$IMG" 2>/dev/null | grep -q 'kernel/firmware/acpi/.*\.aml'; then
  echo "!! $IMG doesn't look like an ACPI override cpio (no kernel/firmware/acpi/*.aml)"; exit 1
fi

echo ">> [1/4] locating EVERY boot config with initrd lines (grub.cfg AND loopback.cfg)"
# Ventoy may boot an ISO via its own grub.cfg OR by loop-mounting it and sourcing
# loopback.cfg — patch them ALL, or the override is silently bypassed on one path.
cfgs=()
while IFS= read -r f; do
  f="${f#\'}"; f="${f%\'}"; [ -n "$f" ] || continue
  xorriso -osirrox on -indev "$IN" -extract "$f" "$tmp/probe" >/dev/null 2>&1 || continue
  grep -qE '^[[:space:]]*initrd(efi)?[[:space:]]' "$tmp/probe" 2>/dev/null && cfgs+=("$f")
done < <(xorriso -osirrox on -indev "$IN" -find / -name '*.cfg' 2>/dev/null)
[ "${#cfgs[@]}" -ge 1 ] || { echo "!! found no *.cfg with initrd lines"; exit 1; }
printf '   config: %s\n' "${cfgs[@]}"

echo ">> [2/4] prepending /acpi_override.img to each initrd line in every config"
maps=(); i=0; total=0
for org in "${cfgs[@]}"; do
  new="$tmp/cfg.$i"; i=$((i+1))
  xorriso -osirrox on -indev "$IN" -extract "$org" "$new.orig" >/dev/null 2>&1
  # insert '/acpi_override.img ' after the 'initrd'/'initrdefi' keyword; real initrd path(s)
  # stay intact (kernel concatenates: our uncompressed override cpio first, casper second).
  sed -E 's#^([[:space:]]*initrd(efi)?)[[:space:]]+#\1 /acpi_override.img #' "$new.orig" > "$new"
  sed -i -E 's/^([[:space:]]*(menuentry|submenu) )("|.)/\1\3[MB-initrd] /' "$new" 2>/dev/null || true
  p="$(grep -cE '^[[:space:]]*initrd(efi)? +/acpi_override.img ' "$new" || true)"
  echo "   $org: $p initrd line(s) patched"
  total=$((total+p))
  maps+=(-map "$new" "$org")
done
[ "$total" -ge 1 ] || { echo "!! nothing patched"; exit 1; }

livemap=()
if [ -n "$LIVE" ]; then
  echo ">> [2b/4] swapping in custom live layer -> /casper/minimal.standard.live.squashfs"
  echo "   $LIVE ($(stat -c%s "$LIVE" | numfmt --to=iec))"
  livemap=(-map "$LIVE" /casper/minimal.standard.live.squashfs)
fi

extramap=()
if [ -n "$EXTRA" ]; then
  echo ">> [2c/4] grafting extra tree -> /honor-fmbp (offline install helper + local repo)"
  echo "   $EXTRA ($(du -sh "$EXTRA" | cut -f1))"
  extramap=(-map "$EXTRA" /honor-fmbp)
fi

echo ">> [3/4] repacking ISO (preserving El Torito BIOS+UEFI boot)"
xorriso -indev "$IN" -outdev "$OUT" \
  -boot_image any replay \
  -map "$IMG" /acpi_override.img \
  "${maps[@]}" \
  "${livemap[@]}" \
  "${extramap[@]}" \
  -end

echo ">> [4/4] verify output"
echo "   override in ISO: $(xorriso -indev "$OUT" -find /acpi_override.img 2>/dev/null | tr -d "'")"
[ -z "$EXTRA" ] || echo "   install helper:  $(xorriso -indev "$OUT" -find /honor-fmbp/honor-fmbp-install.sh 2>/dev/null | tr -d "'")"
echo "   boot images:"; xorriso -indev "$OUT" -report_el_torito plain 2>/dev/null | grep 'El Torito boot img' || true
echo "   size: $(stat -c%s "$OUT" | numfmt --to=iec)"
echo ">> done -> $OUT"
echo "   Boot it in Ventoy 'grub2 mode'. At the menu you should see [MB-initrd] titles."
echo "   After boot, verify the override took: dmesg | grep -i 'ACPI: DSDT'"
