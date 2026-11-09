#!/usr/bin/env bash
# Meson installs the command to bin/pixie and the helpers to share/pixie.
# The prefix in meson.build is /usr. This test overrides it with a temp root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME"

meson setup "$tmp/build" "$ROOT" --prefix="$tmp/usr"
meson install -C "$tmp/build"
test -L "$tmp/usr/bin/pixie"
test -x "$tmp/usr/share/pixie/pixie"
test -f "$tmp/usr/share/pixie/build-order.txt"
test -f "$tmp/usr/share/pixie/abi"
test -x "$tmp/usr/share/pixie/meson-wrapper.sh"
test -x "$tmp/usr/share/pixie/stage-runtime.sh"

target="$(readlink "$tmp/usr/bin/pixie")"
[ "$target" = "../share/pixie/pixie" ]
"$tmp/usr/bin/pixie" --help >/dev/null 2>&1 || {
  status=$?
  [ "$status" -eq 2 ]
}

tree="$(mktemp -d)"
mkdir -p "$tree/lib/arm64-v8a/pkgconfig"
printf '%s\n' 'prefix=/' 'Name: gtk4' 'Version: 4' 'Libs: -lgtk-4' \
  > "$tree/lib/arm64-v8a/pkgconfig/gtk4.pc"
archive="$tmp/gtk.pixie"
tar -C "$tree" -cJf "$archive" .
pins="$tmp/pins.json"
jq -n --arg url "file://${archive}" '{
  packages: [{
    abi: "arm64-v8a",
    repo: "https://gitlab.gnome.org/GNOME/gtk.git",
    name: "gtk",
    track: "4",
    resolved: "abc",
    inputs: "def",
    url: $url
  }]
}' > "$pins"

installed="$("$tmp/usr/bin/pixie" install --prefix "$tmp/opt" --pins "$pins")"
[ "$installed" = "$tmp/opt/lib/pixie/release" ]
grep -F -x "prefix=$tmp/opt/lib/pixie/release" \
  "$tmp/opt/lib/pixie/release/lib/arm64-v8a/pkgconfig/gtk4.pc"

echo "install layout: ok"
