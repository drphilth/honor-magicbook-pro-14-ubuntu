#!/usr/bin/env bash
# fetch-ppa-key.sh — fetch the ppa:drphilth/honor-fmbp signing key and dearmor it
# into keyring/honor-fmbp-ppa.gpg, so honor-fmbp-archive-keyring can ship it.
#
# Launchpad generates a PPA's signing key LAZILY, on the first successful source
# upload. So the sequence is:
#   1. dput the honor-fmbp source package to the PPA (first publish).
#   2. wait for it to publish, then run THIS script (needs network, once).
#   3. rebuild + re-upload honor-fmbp so the keyring deb carries the real key,
#      and build the install ISO (which bundles that keyring deb).
#
# Idempotent: re-running just refreshes the key file.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
PPA_OWNER=drphilth
PPA_NAME=honor-fmbp
OUT="$here/honor-fmbp-ppa.gpg"

command -v curl >/dev/null   || { echo "need curl"; exit 1; }
command -v gpg  >/dev/null   || { echo "need gpg (gnupg)"; exit 1; }
command -v python3 >/dev/null || { echo "need python3"; exit 1; }

echo ">> querying Launchpad for the PPA signing key fingerprint"
fpr=$(curl -fsSL "https://api.launchpad.net/1.0/~${PPA_OWNER}/+archive/ubuntu/${PPA_NAME}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("signing_key_fingerprint") or "")')
if [ -z "$fpr" ]; then
  echo "!! the PPA has no signing key yet."
  echo "   Launchpad only creates it on the FIRST successful upload — dput a source"
  echo "   package to ppa:${PPA_OWNER}/${PPA_NAME} first, let it publish, then re-run."
  exit 1
fi
echo "   fingerprint: $fpr"

echo ">> fetching + dearmoring the key from keyserver.ubuntu.com"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x${fpr}" > "$tmp"
grep -q 'BEGIN PGP PUBLIC KEY' "$tmp" || { echo "!! keyserver did not return an armored key"; exit 1; }

# The keyserver answer is not authenticated by itself: only ship it if it is exactly
# one primary key whose fingerprint is the one Launchpad reports for the PPA.
keys=$(gpg --batch --show-keys --with-colons "$tmp" 2>/dev/null) \
  || { echo "!! gpg could not parse the keyserver answer"; exit 1; }
npub=$(grep -c '^pub:' <<<"$keys" || true)
got=$(awk -F: '/^pub:/ {p = 1; next} p && /^fpr:/ {print $10; exit}' <<<"$keys")
[ "$npub" = 1 ] || { echo "!! expected exactly one key from the keyserver, got $npub"; exit 1; }
[ "${got^^}" = "${fpr^^}" ] \
  || { echo "!! fingerprint mismatch: Launchpad says $fpr, keyserver returned ${got:-none}"; exit 1; }
echo "   keyserver key matches the Launchpad fingerprint"

gpg --dearmor < "$tmp" > "$OUT.new"
[ -s "$OUT.new" ] || { rm -f "$OUT.new"; echo "!! dearmor produced empty output"; exit 1; }
mv "$OUT.new" "$OUT"

echo ">> wrote $OUT ($(stat -c%s "$OUT") bytes)"
echo "   verify:  gpg --show-keys --with-fingerprint $OUT"
