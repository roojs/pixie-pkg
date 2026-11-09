#!/usr/bin/env bash
# Refresh debian/changelog from CHANGELOG.md and refuse a version mismatch.
# The Debian package jobs run this before dpkg-buildpackage.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
chmod +x scripts/release/version.sh scripts/release/changelog.sh \
  scripts/release/sync-debian-changelog.sh

upstream_version() {
  dpkg-parsechangelog -l debian/changelog -S Version | sed 's/-[0-9][0-9]*$//'
}

if [[ "${GITHUB_REF:-}" == refs/tags/* ]]; then
  tag_ver="${GITHUB_REF_NAME#v}"
  if cl_ver="$(./scripts/release/changelog.sh version 2>/dev/null)"; then
    if [[ "${cl_ver}" != "${tag_ver}" ]]; then
      echo "CHANGELOG.md version ${cl_ver} != tag ${tag_ver}" >&2
      exit 1
    fi
    ./scripts/release/sync-debian-changelog.sh
  else
    ./scripts/release/sync-debian-changelog.sh --release "$GITHUB_REF_NAME"
  fi
  ver="$(./scripts/release/version.sh)"
  deb_ver="$(upstream_version)"
  if [[ "${ver}" != "${tag_ver}" ]]; then
    echo "meson version ${ver} != tag ${tag_ver}" >&2
    exit 1
  fi
  expected="${tag_ver//-/\~}"
  if [[ "${deb_ver}" != "${expected}" ]]; then
    echo "debian version ${deb_ver} != tag ${expected}" >&2
    exit 1
  fi
else
  ./scripts/release/sync-debian-changelog.sh
  ver="$(./scripts/release/version.sh)"
  deb_ver="$(upstream_version)"
  cl_ver="$(./scripts/release/changelog.sh packaging-version)"
  if [[ "${ver}" != "${cl_ver}" ]]; then
    echo "meson version ${ver} != CHANGELOG.md ${cl_ver}" >&2
    exit 1
  fi
  expected="${cl_ver//-/\~}"
  if [[ "${deb_ver}" != "${expected}" ]]; then
    echo "debian version ${deb_ver} != CHANGELOG.md ${expected}" >&2
    exit 1
  fi
fi
