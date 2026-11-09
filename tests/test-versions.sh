#!/usr/bin/env bash
# meson.build, default.nix, and debian/changelog carry the same version.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
meson_ver="$(sed -n "s/.*version: '\\([^']*\\)'.*/\\1/p" "$ROOT/meson.build" | head -n 1)"
nix_ver="$(sed -n 's/^[[:space:]]*version = "\([^"]*\)".*/\1/p' "$ROOT/default.nix" | head -n 1)"
deb_ver="$(dpkg-parsechangelog -l "$ROOT/debian/changelog" -S Version | cut -d- -f1)"
script_ver="$("$ROOT/scripts/release/version.sh")"

[ -n "$meson_ver" ]
[ "$meson_ver" = "$nix_ver" ]
[ "$meson_ver" = "$deb_ver" ]
[ "$meson_ver" = "$script_ver" ]
echo "version $meson_ver: ok"
