#!/usr/bin/env bash
# The Meson wrapper appends the activated pixie cross file on setup.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/sysroot/share/pixiewood" "$tmp/bin"
cat > "$tmp/sysroot/share/pixiewood/MANIFEST.json" << EOF
{"format": 1, "abi": "arm64-v8a", "prefix_token": "@PIXIEWOOD_SYSROOT@", "activated_prefix": null}
EOF
"$ROOT/scripts/pixie-tree.sh" activate "$tmp/sysroot"
test -f "$tmp/sysroot/share/pixiewood/pixie.cross"

cat > "$tmp/bin/fake-meson" << 'EOF'
#!/bin/bash
printf '%s\n' "$@"
EOF
chmod +x "$tmp/bin/fake-meson"

output="$(
  PIXIEWOOD_PIXIE="$tmp/sysroot" \
  PIXIEWOOD_REAL_MESON="$tmp/bin/fake-meson" \
    "$ROOT/scripts/meson-wrapper.sh" setup --cross-file toolchain.cross builddir sourcedir
)"
first="$(printf '%s\n' "$output" | head -n1)"
second="$(printf '%s\n' "$output" | sed -n '2p')"
third="$(printf '%s\n' "$output" | sed -n '3p')"
[ "$first" = "setup" ]
[ "$second" = "--cross-file" ]
[ "$third" = "$tmp/sysroot/share/pixiewood/pixie.cross" ]
printf '%s\n' "$output" | grep -q '^toolchain.cross$'
printf '%s\n' "$output" | grep -qx 'builddir'
printf '%s\n' "$output" | grep -qx 'sourcedir'

forward="$(
  PIXIEWOOD_REAL_MESON="$tmp/bin/fake-meson" \
    "$ROOT/scripts/meson-wrapper.sh" compile -C builddir
)"
[ "$forward" = "compile
-C
builddir" ]

echo "meson wrapper: ok"
