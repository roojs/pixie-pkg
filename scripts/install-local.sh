#!/usr/bin/env bash
# Build pixie with Nix and copy it into a prefix. The prefix defaults to /usr.
set -euo pipefail

prefix="${PREFIX:-/usr}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v nix-build >/dev/null 2>&1; then
  echo "nix-build is not installed." >&2
  echo "Install with Meson instead: meson setup build && meson install -C build" >&2
  exit 1
fi

if [ ! -w "$prefix" ] && [ ! -w "$(dirname "$prefix")" ]; then
  echo "Cannot write to $prefix." >&2
  echo "Run: sudo PREFIX=$prefix $0" >&2
  exit 1
fi

out="$(nix-build "$root" --no-out-link)"
mkdir -p "$prefix/bin" "$prefix/share"
rm -rf "$prefix/share/pixie"
cp -a "$out/share/pixie" "$prefix/share/pixie"
ln -sfn ../share/pixie/pixie "$prefix/bin/pixie"
echo "Installed pixie into $prefix"
echo "$prefix/bin/pixie"
