#!/usr/bin/env bash
# meson.build, CHANGELOG.md, debian/changelog, and the RPM changelog agree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chmod +x "$ROOT/scripts/release/changelog.sh" "$ROOT/scripts/release/version.sh"
"$ROOT/scripts/release/changelog.sh" check
echo "version $("$ROOT/scripts/release/version.sh"): ok"
