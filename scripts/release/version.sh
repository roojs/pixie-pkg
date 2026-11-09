#!/usr/bin/env bash
# Print the pixie version from meson.build.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sed -n "s/.*version: '\\([^']*\\)'.*/\\1/p" "$root/meson.build" | head -n 1
