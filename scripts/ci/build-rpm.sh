#!/usr/bin/env bash
# Build the pixie-pkg RPM from this checkout (Fedora or openSUSE).
# Usage: scripts/ci/build-rpm.sh [version]
# Version defaults to CHANGELOG.md, and must match meson.build and a vX.Y.Z tag.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
chmod +x "$ROOT/scripts/release/version.sh" "$ROOT/scripts/release/changelog.sh"

if [ "$#" -ge 1 ] && [ -n "$1" ]; then
  ver="$1"
elif [ -n "${GITHUB_REF_NAME:-}" ] && [[ "${GITHUB_REF:-}" == refs/tags/v* ]]; then
  ver="${GITHUB_REF_NAME#v}"
  cl_ver="$("$ROOT/scripts/release/changelog.sh" version)"
  if [ "$cl_ver" != "$ver" ]; then
    echo "CHANGELOG.md version ${cl_ver} != tag ${ver}" >&2
    exit 1
  fi
else
  ver="$("$ROOT/scripts/release/changelog.sh" packaging-version)"
fi
if [ -z "$ver" ]; then
  echo "Could not determine package version" >&2
  exit 1
fi
meson_ver="$("$ROOT/scripts/release/version.sh")"
if [ "$meson_ver" != "$ver" ]; then
  echo "meson version ${meson_ver} != ${ver}" >&2
  exit 1
fi

echo "Building pixie-pkg RPM version ${ver}"

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
  --transform "s|^\\./|pixie-pkg-${ver}/|" \
  -czf "${TOPDIR}/SOURCES/pixie-pkg-${ver}.tar.gz" \
  .

cp packaging/rpm/pixie-pkg.spec "${TOPDIR}/SPECS/pixie-pkg.spec"
"$ROOT/scripts/release/changelog.sh" sync \
  --splice-spec "${TOPDIR}/SPECS/pixie-pkg.spec"
rpmbuild -bb \
  --define "_topdir ${TOPDIR}" \
  --define "pixie_version ${ver}" \
  "${rpm_dist_args[@]}" \
  "${TOPDIR}/SPECS/pixie-pkg.spec"

mkdir -p "${ROOT}/artifacts"
find "${TOPDIR}/RPMS" -type f -name '*.rpm' ! -name '*.src.rpm' \
  -exec cp -v {} "${ROOT}/artifacts/" \;
ls -lh "${ROOT}/artifacts"
