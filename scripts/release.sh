#!/usr/bin/env bash
# Verify the tree is ready, then tag + push. That is all.
#
# 1. Read latest ## [X.Y.Z] - Unreleased from CHANGELOG.md
# 2. Exit if tag vX.Y.Z already exists (local or origin)
#    unless --retry: delete that tag locally and on origin, then continue
# 3. Verify: on main, clean tree, notes, meson version,
#    debian/changelog, and the RPM %changelog
# 4. git tag -a + git push (main + tag) → GitHub Actions builds packages
#
# When the packaging changelogs disagree with CHANGELOG.md, rewrite them
# and stop so they can be committed. A clean tree is tagged as-is.
# GitHub Actions copies CHANGELOG.md into Debian and RPM packaging again
# after the tag lands. This script does not build packages.
#
# AGENTS ARE BANNED from running this script. Do not tag, push, or release
# on the user's behalf. Do not unset CURSOR_AGENT, spoof the environment,
# invoke git tag/push directly, or otherwise work around this guard.
# Only the human runs scripts/release.sh in a normal terminal.
set -euo pipefail

if [[ "${CURSOR_AGENT:-}" == "1" ]]; then
  cat >&2 <<'EOF'
error: agents are banned from running scripts/release.sh.

Do not work around this (unset CURSOR_AGENT, fake the env, call git tag/push
yourself, etc.). The human must run scripts/release.sh in a normal terminal.
EOF
  exit 1
fi

retry=0
for arg in "$@"; do
  case "${arg}" in
    --retry)
      retry=1
      ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/release.sh [--retry]

Create an annotated tag from CHANGELOG.md and push it to origin.

  --retry   Delete the existing version tag and the matching
            v*-packages tag locally and on origin, then retag HEAD
            and push (use after a failed release CI run).
EOF
      exit 0
      ;;
    *)
      echo "error: unknown option: ${arg}" >&2
      echo "Usage: scripts/release.sh [--retry]" >&2
      exit 1
      ;;
  esac
done

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "${root}"

if [[ ! -f CHANGELOG.md ]]; then
  echo "error: missing CHANGELOG.md" >&2
  exit 1
fi

chmod +x scripts/release/changelog.sh scripts/release/version.sh \
  scripts/release/sync-debian-changelog.sh
ver="$(scripts/release/changelog.sh version)"
tag="v${ver}"
notes="$(scripts/release/changelog.sh notes)"

echo "CHANGELOG.md latest: ${ver}"
echo "Tag: ${tag}"
echo "---- notes ----"
echo "${notes}"
echo "---------------"

meson_ver="$(scripts/release/version.sh)"
if [[ "${meson_ver}" != "${ver}" ]]; then
  echo "error: meson.build version ${meson_ver} != CHANGELOG.md ${ver}" >&2
  exit 1
fi

if ! scripts/release/changelog.sh check-release; then
  scripts/release/sync-debian-changelog.sh
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: packaging changelogs were updated from CHANGELOG.md. Commit them and run scripts/release.sh again." >&2
    git status --short >&2
    exit 1
  fi
  echo "error: release check failed" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree not clean — commit or stash before releasing" >&2
  git status --short >&2
  exit 1
fi

branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "${branch}" != "main" ]]; then
  echo "error: run scripts/release.sh on main (current branch is ${branch})" >&2
  exit 1
fi

git fetch --tags origin 2>/dev/null || true

if [[ "${retry}" -eq 1 ]]; then
  for t in "${tag}" "${tag}-packages"; do
    if git rev-parse -q --verify "refs/tags/${t}" >/dev/null; then
      echo "Deleting local tag ${t}..."
      git tag -d "${t}"
    fi
    if git ls-remote --exit-code --tags origin "refs/tags/${t}" >/dev/null 2>&1; then
      echo "Deleting origin tag ${t}..."
      git push origin --delete "refs/tags/${t}"
    fi
  done
fi

if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
  echo "Tag ${tag} already exists locally — nothing to do."
  echo "Re-run with --retry to delete it and retag HEAD." >&2
  exit 0
fi

if git ls-remote --exit-code --tags origin "refs/tags/${tag}" >/dev/null 2>&1; then
  echo "Tag ${tag} already exists on origin — nothing to do."
  echo "Re-run with --retry to delete it and retag HEAD." >&2
  exit 0
fi

echo "Creating annotated tag ${tag}..."
git tag -a "${tag}" -m "${tag}"

branch="$(git rev-parse --abbrev-ref HEAD)"
echo "Pushing ${branch} and ${tag} to origin..."
git push -u origin "${branch}"
git push origin "${tag}"

echo "Released ${tag}. GitHub Actions will copy CHANGELOG.md into debian/changelog and the RPM spec, then build .deb/.rpm."
