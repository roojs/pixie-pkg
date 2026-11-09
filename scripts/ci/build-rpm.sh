#!/usr/bin/env bash
# Build the pixie RPM from this checkout (Fedora or openSUSE).
# Usage: scripts/ci/build-rpm.sh [version]
# Version defaults to meson.build, and must match a vX.Y.Z tag.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
chmod +x "$ROOT/scripts/release/version.sh"

if [ "$#" -ge 1 ] && [ -n "$1" ]; then
  ver="$1"
else
  ver="$("$ROOT/scripts/release/version.sh")"
fi
if [ -z "$ver" ]; then
  echo "Could not determine package version" >&2
  exit 1
fi
if [ -n "${GITHUB_REF_NAME:-}" ] && [[ "${GITHUB_REF:-}" == refs/tags/v* ]]; then
  tag_ver="${GITHUB_REF_NAME#v}"
  if [ "$ver" != "$tag_ver" ]; then
    echo "meson version ${ver} != tag ${tag_ver}" >&2
    exit 1
  fi
fi

echo "Building pixie RPM version ${ver}"

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

. /etc/os-release

case "${ID}" in
  fedora)
    run_root dnf -y install --setopt=install_weak_deps=False \
      rpm-build \
      meson ninja-build
    rpm_dist_args=()
    ;;
  opensuse* | opensuse-tumbleweed | slfo)
    run_root zypper --non-interactive install --force-resolution \
      --no-recommends \
      rpm-build \
      meson ninja
    # Keep the filename free of a Fedora-style dist tag.
    rpm_dist_args=(--define 'dist %{nil}')
    ;;
  *)
    echo "Unsupported distro for RPM build: ${ID}" >&2
    exit 1
    ;;
esac

TOPDIR="${ROOT}/.rpmbuild"
rm -rf "$TOPDIR"
mkdir -p "$TOPDIR"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

tar --exclude='./.git' \
  --exclude='./.rpmbuild' \
  --exclude='./build' \
  --exclude='./artifacts' \
  --transform "s|^\\./|pixie-${ver}/|" \
  -czf "${TOPDIR}/SOURCES/pixie-${ver}.tar.gz" \
  .

cp packaging/rpm/pixie.spec "${TOPDIR}/SPECS/pixie.spec"
rpmbuild -bb \
  --define "_topdir ${TOPDIR}" \
  --define "pixie_version ${ver}" \
  "${rpm_dist_args[@]}" \
  "${TOPDIR}/SPECS/pixie.spec"

mkdir -p "${ROOT}/artifacts"
find "${TOPDIR}/RPMS" -type f -name '*.rpm' ! -name '*.src.rpm' \
  -exec cp -v {} "${ROOT}/artifacts/" \;
ls -lh "${ROOT}/artifacts"
