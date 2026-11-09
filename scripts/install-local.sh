#!/usr/bin/env bash
# Copy the pixie-pkg command onto this machine. The prefix defaults to /usr.
set -euo pipefail

prefix="${PREFIX:-/usr}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -w "$prefix" ] && [ ! -w "$(dirname "$prefix")" ]; then
  echo "Cannot write to $prefix." >&2
  echo "Run: sudo PREFIX=$prefix $0" >&2
  exit 1
fi

share="$prefix/share/pixie-pkg"
mkdir -p "$prefix/bin" "$share"
rm -rf "$share"
mkdir -p "$share"

install -m 0755 \
  "$root/scripts/pixie-pkg" \
  "$root/scripts/pixie-tree.sh" \
  "$root/scripts/activate-pixie.sh" \
  "$root/scripts/stage-runtime.sh" \
  "$root/scripts/meson-wrapper.sh" \
  "$root/scripts/verify-pixie.sh" \
  "$share/"
install -m 0644 "$root/scripts/pixie-common.sh" "$share/pixie-common.sh"
install -m 0644 "$root/data/abi" "$share/abi"
install -m 0644 "$root/data/build-order.txt" "$share/build-order.txt"
ln -sfn ../share/pixie-pkg/pixie-pkg "$prefix/bin/pixie-pkg"

echo "Installed pixie-pkg into $prefix"
echo "$prefix/bin/pixie-pkg"
