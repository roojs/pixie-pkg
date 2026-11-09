#!/usr/bin/env bash
# The release command refuses agents. Notes for a tag come from CHANGELOG.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chmod +x "$ROOT/scripts/release.sh" \
  "$ROOT/scripts/release/changelog.sh" \
  "$ROOT/scripts/release/render-release-notes.sh" \
  "$ROOT/scripts/release/version.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

set +e
CURSOR_AGENT=1 "$ROOT/scripts/release.sh" >"$tmp/out" 2>"$tmp/err"
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo "scripts/release.sh ran under CURSOR_AGENT=1" >&2
  exit 1
fi
grep -q 'agents are banned' "$tmp/err"
if [[ -s "$tmp/out" ]]; then
  echo "banned release script wrote to stdout" >&2
  cat "$tmp/out" >&2
  exit 1
fi

ver="$("$ROOT/scripts/release/changelog.sh" packaging-version)"
meson="$("$ROOT/scripts/release/version.sh")"
[[ "$ver" == "$meson" ]]

"$ROOT/scripts/release/render-release-notes.sh" "v${ver}" "$tmp/notes.md"
grep -q 'roojs.github.io/repos' "$tmp/notes.md"
grep -q 'pixiewood-pkgs' "$tmp/notes.md"
grep -q '^- ' "$tmp/notes.md"

if ready="$("$ROOT/scripts/release/changelog.sh" version 2>/dev/null)"; then
  [[ "$ready" == "$ver" ]]
  "$ROOT/scripts/release/changelog.sh" check-release >/dev/null
fi

echo "release info: ok"
