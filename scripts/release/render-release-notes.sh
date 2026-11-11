#!/usr/bin/env bash
# Write GitHub release notes from CHANGELOG.md.
# Debian and RPM files are attached to this same version tag.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <tag> [output-file]" >&2
  exit 1
fi

TAG="$1"
OUTPUT="${2:-$ROOT/release-notes.md}"
"$ROOT/scripts/release/changelog.sh" release-notes "$TAG" -o "$OUTPUT"

tmp="$(mktemp)"
{
  echo "Debian and RPM packages for ${TAG}."
  echo
  echo "Prefer the [roojs package repositories](https://roojs.github.io/repos/) (\`apt\`, \`dnf\`, \`zypper\`). This GitHub Release is the matching file set."
  echo
  echo "One \`.deb\` and one \`.rpm\`. The apt repositories share the \`.deb\`. The RPM repositories share the \`.rpm\`."
  echo
  echo "After installing, \`sudo pixie-pkg install\` fills \`/usr/lib/pixie\` from [pixiewood-pkgs](https://github.com/roojs/pixiewood-pkgs)."
  echo
  echo "---"
  echo
  cat "$OUTPUT"
} > "$tmp"
mv "$tmp" "$OUTPUT"
