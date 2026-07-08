#!/usr/bin/env bash
# Pull denis-bb's reference DSDT material for cross-checking our own build.
# Run on a networked machine (e.g. the desktop) so the files travel on the stick.
set -euo pipefail
cd "$(dirname "$0")"

repo="https://github.com/denis-bb/honor-fmb-p-dsdt"
if command -v git >/dev/null; then
  rm -rf honor-fmb-p-dsdt
  git clone --depth 1 "$repo" honor-fmb-p-dsdt
  echo "Cloned into $(pwd)/honor-fmb-p-dsdt"
else
  echo "git not found. Manually download $repo and unzip here."
fi
