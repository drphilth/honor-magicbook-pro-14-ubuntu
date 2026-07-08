#!/usr/bin/env bash
# honor-fmbp-install.sh — run from the Ubuntu LIVE session AFTER the installer
# finishes but BEFORE the first reboot. It chroots the freshly-installed system
# and installs the boot-critical + pure-file honor-fmbp packages from the local
# apt repo bundled on this ISO, ENTIRELY OFFLINE:
#
#     honor-fmbp-dsdt             bakes the corrected DSDT into the INSTALLED
#                                 initramfs (postinst GNVS-selects the SKU from
#                                 the live firmware table + runs update-initramfs)
#                                 -> first boot sees NVMe + touchpad
#     honor-fmbp-config           input/power quirks (udev/hwdb/battery/dconf)
#     honor-fmbp-archive-keyring  configures ppa:drphilth/honor-fmbp as a file
#                                 source (no network) for updates after boot
#
# The DKMS drivers (fan/kbd), fingerprint and audio firmware are DELIBERATELY
# NOT installed here: they build against the running kernel and need MOK
# enrollment (Secure Boot) + the archive, so they go in on first boot, online:
#
#     sudo apt update && sudo apt install honor-magicbook-pro-14
#
# Usage (from the live-session terminal, e.g. off the Ventoy stick / ISO):
#     sudo /cdrom/honor-fmbp/honor-fmbp-install.sh [TARGET]
#
# TARGET may be a mounted root directory (e.g. /target) OR a block device (e.g.
# /dev/sda2), which the script mounts itself. With no argument it uses /target if
# the installer left it mounted; otherwise it offers an interactive pick of the
# installed Ubuntu roots it can find (the RUNNING system is always excluded, so
# it can never target the live/host system by mistake).
#
# The local repo is expected next to this script at ./repo (built by
# boot/build-install-iso.sh); override with REPO=/path for testing.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
REPO="${REPO:-$here/repo}"
# Install the pure-file, offline-safe set. Only honor-fmbp-dsdt is truly
# boot-critical (NVMe/touchpad); config + keyring are important but not
# boot-blocking, and the keyring deb may be absent on a pre-publish TEST ISO
# (its build needs the real PPA key), so the fallback is dsdt alone.
PKGS="honor-fmbp-dsdt honor-fmbp-config honor-fmbp-archive-keyring"
CRITICAL="honor-fmbp-dsdt"

[ "$(id -u)" = 0 ] || { echo "!! run as root (sudo $0)"; exit 1; }
[ -d "$REPO" ]     || { echo "!! local repo not found at $REPO"; exit 1; }
ls "$REPO"/honor-fmbp-dsdt_*.deb >/dev/null 2>&1 \
  || { echo "!! no honor-fmbp-dsdt deb in $REPO — was the ISO built by build-install-iso.sh?"; exit 1; }
[ -e "$REPO/Packages" ] || [ -e "$REPO/Packages.gz" ] \
  || { echo "!! no Packages index in $REPO — run dpkg-scanpackages there, or build via build-install-iso.sh"; exit 1; }

# ---- locate the installed root -------------------------------------------------
# A valid target: has /etc/os-release + /boot + /usr/bin, an installed kernel,
# and is NOT the running live system ('/').
valid_root() {
  local r="$1"
  [ -n "$r" ] && [ -d "$r" ] || return 1
  [ "$(readlink -f "$r")" != / ] || return 1
  [ -e "$r/etc/os-release" ] && [ -d "$r/usr/bin" ] || return 1
  ls "$r"/boot/vmlinuz-* >/dev/null 2>&1 || return 1
  return 0
}

# Mount a block device's ROOT filesystem at a fresh temp dir (handles the btrfs
# @ subvol layout Ubuntu uses). $2=ro for read-only probing. Echoes the mountpoint.
mount_root_dev() {
  local dev="$1" mode="${2:-rw}" mp fstype
  mp="$(mktemp -d)"
  fstype="$(lsblk -dno FSTYPE "$dev" 2>/dev/null)"
  if [ "$fstype" = btrfs ]; then
    mount -o "$mode",subvol=@ "$dev" "$mp" 2>/dev/null \
      || mount -o "$mode" "$dev" "$mp" 2>/dev/null || { rmdir "$mp"; return 1; }
  else
    mount -o "$mode" "$dev" "$mp" 2>/dev/null || { rmdir "$mp"; return 1; }
  fi
  echo "$mp"
}

# Device backing the RUNNING root (strip any [/@subvol] suffix) — always excluded
# from auto-detection so we can never target the live/host system by mistake.
RUNROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*//')"
SELF_MOUNTED=""   # set to a mountpoint if WE mounted the target (so cleanup unmounts it)

arg="${1:-}"
if [ -n "$arg" ] && [ -b "$arg" ]; then
  echo ">> mounting target device $arg"
  TARGET="$(mount_root_dev "$arg" rw)" || { echo "!! could not mount $arg"; exit 1; }
  SELF_MOUNTED="$TARGET"
  valid_root "$TARGET" || { echo "!! $arg is not an installed Ubuntu root"; exit 1; }
elif [ -n "$arg" ]; then
  valid_root "$arg" || { echo "!! '$arg' does not look like an installed Ubuntu root"; exit 1; }
  TARGET="$arg"
elif valid_root /target; then
  TARGET=/target
else
  echo ">> installer left no /target — scanning for installed Ubuntu roots"
  echo "   (the running system, $RUNROOT_SRC, is excluded)"
  devs=(); descs=()
  while read -r name fstype; do
    case "$fstype" in ext4|btrfs|xfs) ;; *) continue ;; esac
    dev="/dev/$name"
    [ "$dev" = "$RUNROOT_SRC" ] && continue
    mp="$(mount_root_dev "$dev" ro)" || continue
    if valid_root "$mp"; then
      pretty="$(sed -n 's/^PRETTY_NAME=//p' "$mp/etc/os-release" 2>/dev/null | tr -d '\"')"
      instdate="$(stat -c %y "$mp/var/log/installer" 2>/dev/null | cut -d. -f1)"
      sz="$(lsblk -dno SIZE "$dev" | tr -d ' ')"; model="$(lsblk -dno MODEL "$dev" | sed 's/ *$//')"
      tran="$(lsblk -dno TRAN "$dev")"
      devs+=("$dev")
      descs+=("$dev  $sz  ${tran:+$tran }${model:-?}  —  ${pretty:-Linux}${instdate:+  (installed $instdate)}")
    fi
    umount "$mp" 2>/dev/null; rmdir "$mp" 2>/dev/null
  done < <(lsblk -rno NAME,FSTYPE | awk 'NF==2')
  [ "${#devs[@]}" -gt 0 ] || {
    echo "!! no installed Ubuntu root found (excluding this running system)."
    echo "   Pass the target device explicitly, e.g.:  sudo $0 /dev/sda2"; exit 1; }
  echo "   installed Ubuntu roots found:"
  i=1; for d in "${descs[@]}"; do echo "     [$i] $d"; i=$((i+1)); done
  printf "   Which one did you just install to? [1-%d, q=quit]: " "${#devs[@]}"
  read -r pick </dev/tty || pick=q
  case "${pick:-q}" in
    q|Q|'') echo "aborted — no target selected."; exit 1 ;;
    *[!0-9]*) echo "!! '$pick' is not a number."; exit 1 ;;
  esac
  { [ "$pick" -ge 1 ] && [ "$pick" -le "${#devs[@]}" ]; } || { echo "!! out of range."; exit 1; }
  seldev="${devs[$((pick-1))]}"
  echo ">> mounting selected target $seldev"
  TARGET="$(mount_root_dev "$seldev" rw)" || { echo "!! could not mount $seldev"; exit 1; }
  SELF_MOUNTED="$TARGET"
  valid_root "$TARGET" || { echo "!! $seldev is not an installed Ubuntu root"; exit 1; }
fi
echo ">> installed root: $TARGET  ($([ -n "$SELF_MOUNTED" ] && echo "mounted by us" || echo "pre-mounted"))"

# ---- set up cleanup NOW, so an abort (or any later failure) unmounts cleanly ---
MOUNTS="/dev /dev/pts /proc /sys /run"
cleanup() {
  set +e
  # ephemeral repo copy + temp apt source we drop into the target
  rm -f  "$TARGET/etc/apt/sources.list.d/honor-fmbp-local.sources"
  rm -rf "$TARGET/run/honor-fmbp-repo"
  for m in /run /sys /proc /dev/pts /dev; do
    mountpoint -q "$TARGET$m" && umount -l "$TARGET$m" 2>/dev/null
  done
  if [ -n "$SELF_MOUNTED" ]; then          # unmount the target only if WE mounted it
    umount "$SELF_MOUNTED" 2>/dev/null || umount -l "$SELF_MOUNTED" 2>/dev/null
    rmdir "$SELF_MOUNTED" 2>/dev/null
  fi
}
trap cleanup EXIT

# ---- CONFIRM the target before writing anything --------------------------------
TARGET_DEV="$(findmnt -no SOURCE --target "$TARGET" 2>/dev/null | sed 's/\[.*//')"
echo "   ┌──────────────────────────────────────────────────────────────"
echo "   │ ABOUT TO INSTALL honor-fmbp INTO — THIS MODIFIES THIS DISK:"
echo "   │   device: ${TARGET_DEV:-?}   $(lsblk -dno SIZE,MODEL,TRAN "${TARGET_DEV:-/dev/null}" 2>/dev/null | tr -s ' ')"
echo "   │   root:   $TARGET"
echo "   │   distro: $(sed -n 's/^PRETTY_NAME=//p' "$TARGET/etc/os-release" | tr -d '\"')"
echo "   └──────────────────────────────────────────────────────────────"
if [ "${ASSUME_YES:-0}" != 1 ]; then
  printf "   Type YES (capitals) to proceed; anything else aborts: "
  read -r ans </dev/tty || ans=""
  [ "$ans" = YES ] || { echo "aborted — nothing written."; exit 1; }
fi
for m in $MOUNTS; do
  mkdir -p "$TARGET$m"
  mountpoint -q "$TARGET$m" || mount --bind "$m" "$TARGET$m"
done

# ---- expose the local repo INSIDE the target, offline -------------------------
# Copy (not bind — survives the medium being pulled) into /run so it's ephemeral.
mkdir -p "$TARGET/run/honor-fmbp-repo"
cp "$REPO"/*.deb "$REPO"/Packages* "$TARGET/run/honor-fmbp-repo/" 2>/dev/null || true
cat > "$TARGET/etc/apt/sources.list.d/honor-fmbp-local.sources" <<'EOF'
# Ephemeral local repo for the offline pre-first-boot install (removed after).
Types: deb
URIs: file:/run/honor-fmbp-repo
Suites: ./
Trusted: yes
EOF

# ---- install, offline: update ONLY the local list, then install ---------------
# Restrict `apt update` to our file source so it never blocks on the network;
# already-installed deps (dconf-cli, udev, initramfs-tools, pkexec) satisfy the
# rest without an archive index.
APT_LOCAL='-o Dir::Etc::sourcelist=/etc/apt/sources.list.d/honor-fmbp-local.sources -o Dir::Etc::sourceparts=/dev/null -o APT::Get::List-Cleanup=0'
echo ">> [chroot] refreshing local repo index (offline)"
chroot "$TARGET" /bin/sh -c "apt-get $APT_LOCAL update"

# Only ask for packages that are actually in the bundled repo (a pre-publish
# test ISO may lack honor-fmbp-archive-keyring).
avail=""
for name in $PKGS; do ls "$REPO"/${name}_*.deb >/dev/null 2>&1 && avail="$avail $name"; done
avail="${avail# }"
echo ">> [chroot] installing:$avail"
if chroot "$TARGET" /bin/sh -c "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $avail"; then
  echo ">> all packages installed"
else
  echo "!! full install failed — retrying the boot-critical subset ($CRITICAL) so the"
  echo "   machine still boots; the rest can go in online after first boot."
  chroot "$TARGET" /bin/sh -c "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $CRITICAL"
fi

# ---- verify the DSDT actually landed in the INSTALLED initramfs ---------------
echo ">> verifying the corrected DSDT is baked into the installed initramfs"
sel="$(readlink -f "$TARGET/usr/share/honor-fmbp/dsdt.aml" 2>/dev/null || true)"
echo "   selected SKU AML: ${sel:-<none>}"
# List the initramfs with whichever tool the target's generator provides:
# initramfs-tools ships lsinitramfs, dracut ships lsinitrd. Both show the early
# cpio's kernel/firmware/acpi/dsdt.aml entry.
list_initrd() {  # $1 = /boot/<basename>
  chroot "$TARGET" sh -c "command -v lsinitramfs >/dev/null 2>&1 && lsinitramfs '$1' \
    || (command -v lsinitrd >/dev/null 2>&1 && lsinitrd '$1')" 2>/dev/null
}
ok=0
for img in "$TARGET"/boot/initrd.img-*; do
  [ -e "$img" ] || continue
  if list_initrd "/boot/$(basename "$img")" | grep -q 'kernel/firmware/acpi/dsdt.aml'; then
    echo "   ✅ $(basename "$img") carries kernel/firmware/acpi/dsdt.aml"
    ok=1
  else
    echo "   ⚠️  $(basename "$img") has NO DSDT override"
  fi
done
[ "$ok" = 1 ] || { echo "!! no installed initramfs carries the DSDT — DO NOT REBOOT; investigate."; exit 1; }

echo
echo "✅ pre-first-boot install complete. You can reboot into the installed system."
echo "   First boot will have working NVMe, touchpad, touchscreen + quirks."
echo "   Then finish the rest (DKMS drivers, fingerprint, audio fw) online:"
echo "     sudo apt update && sudo apt install honor-magicbook-pro-14"
