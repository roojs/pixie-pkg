#!/usr/bin/env bash
# Staging must not copy files from outside the sysroot into the app tree.
#
# These checks fail while scripts/stage-runtime.sh follows a library or
# schema path that leaves the sysroot, and while scripts/pixie-tree.sh
# activate joins an unconfined abi onto a filesystem path. They pass once
# those copies and writes stay inside the trees they were given.
#
# Run: bash tests/test-stage-runtime-confine.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIXIE="$ROOT/scripts/pixie-pkg"
STAGE="$ROOT/scripts/stage-runtime.sh"
# shellcheck source=../scripts/pixie-common.sh
source "$ROOT/scripts/pixie-common.sh"

MARKER=PLACEHOLDER
REPO=https://example.com/widgets.git

for tool in jq curl python3 tar; do
  command -v "$tool" >/dev/null
done

# Case bodies run under `if`, which disables errexit, so each check is explicit.
require() {
  if ! "$@"; then
    echo "check failed: $*" >&2
    return 1
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

rel_to() {
  python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$1" "$2"
}

normpath() {
  python3 -c 'import os,sys; print(os.path.normpath(sys.argv[1]))' "$1"
}

is_known_abi() {
  local abi=$1 arch got
  while read -r arch got _; do
    if [ -z "${arch:-}" ] || [ "${arch#\#}" != "$arch" ]; then
      continue
    fi
    if [ "$got" = "$abi" ]; then
      return 0
    fi
  done < "$ROOT/data/abi"
  return 1
}

prepare_case() {
  local name=$1
  work="$tmp/$name"
  export HOME="$work/home"
  rm -rf "$work"
  mkdir -p "$HOME/.ssh/arm64-v8a"
  printf '%s\n' "$MARKER" > "$HOME/.ssh/marker.txt"
  printf '%s\n' "$MARKER" > "$HOME/.ssh/arm64-v8a/marker.txt"
  private_before="$(find -P "$HOME/.ssh" -printf '%y %P\n' | LC_ALL=C sort)"
}

private_unchanged() {
  local now
  now="$(find -P "$HOME/.ssh" -printf '%y %P\n' | LC_ALL=C sort)"
  if [ "$now" != "$private_before" ]; then
    echo "private directory changed" >&2
    printf 'before:\n%s\nafter:\n%s\n' "$private_before" "$now" >&2
    return 1
  fi
}

pins_for() {
  local abi=$1 archive=$2 dest=$3
  jq -n --arg abi "$abi" --arg url "file://${archive}" --arg repo "$REPO" '{
    packages: [{
      abi: $abi,
      repo: $repo,
      name: "gtk",
      track: "1",
      resolved: "abc",
      inputs: "def",
      url: $url
    }]
  }' > "$dest"
}

install_user() {
  local pins=$1
  shift
  set +e
  "$PIXIE" install --user --pins "$pins" "$@" >"$work/install.out" 2>"$work/install.err"
  printf '%s' $? > "$work/install.status"
  set -e
}

stage_into() {
  local sysroot=$1 app=$2
  mkdir -p "$(dirname "$app")"
  set +e
  "$STAGE" "$sysroot" "$app" >"$work/stage.out" 2>"$work/stage.err"
  printf '%s' $? > "$work/stage.status"
  set -e
}

stage_status() {
  cat "$work/stage.status"
}

contains_marker() {
  local root=$1 f
  [ -e "$root" ] || return 1
  while IFS= read -r -d '' f; do
    if grep -q -F -e "$MARKER" -- "$f"; then
      echo "private content copied to $f" >&2
      return 0
    fi
  done < <(find -P "$root" -type f -print0)
  return 1
}

symlink_leaves() {
  local root=$1 extra=${2:-} link resolved
  [ -e "$root" ] || return 1
  while IFS= read -r -d '' link; do
    resolved="$(readlink -m "$link")"
    case "$resolved" in
      "$root"|"$root"/*) continue ;;
    esac
    if [ -n "$extra" ]; then
      case "$resolved" in
        "$extra"|"$extra"/*) continue ;;
      esac
    fi
    echo "symlink $link resolves outside at $resolved" >&2
    return 0
  done < <(find -P "$root" -type l -print0)
  return 1
}

app_is_confined() {
  local app=$1 sysroot=${2:-}
  if contains_marker "$app"; then
    return 1
  fi
  if symlink_leaves "$app" "$sysroot"; then
    return 1
  fi
}

regular_file() {
  [ -f "$1" ] && [ ! -L "$1" ]
}

user_sysroot() {
  printf '%s\n' "$HOME/.local/lib/pixie/release"
}

# Documented user tree: ~/.local/lib/pixie/release
lib_symlink_target() {
  rel_to "$HOME/.ssh" "$HOME/.local/lib/pixie/release/lib"
}

schema_symlink_target() {
  rel_to "$HOME/.ssh" "$HOME/.local/lib/pixie/release/share/glib-2.0"
}

ancestor_symlink_target() {
  rel_to "$HOME/.ssh" "$HOME/.local/lib/pixie/release"
}

nested_symlink_target() {
  rel_to "$HOME/.ssh/marker.txt" "$HOME/.local/lib/pixie/release/lib/arm64-v8a"
}

write_benign_library() {
  local tree=$1 abi=$2
  mkdir -p "$tree/lib/$abi/pkgconfig" "$tree/share/glib-2.0/schemas"
  printf '%s\n' 'prefix=/' 'Name: gtk4' 'Version: 1' 'Libs: -lgtk' \
    > "$tree/lib/$abi/pkgconfig/gtk4.pc"
  printf '%s\n' 'benign-library' > "$tree/lib/$abi/libgtk.so"
  ln -s libgtk.so "$tree/lib/$abi/internal-link"
  printf '%s\n' '<schema/>' > "$tree/share/glib-2.0/schemas/app.gschema.xml"
}

expect_benign_staged() {
  local app=$1 abi=$2 sysroot=$3
  require regular_file "$app/lib/$abi/libgtk.so"
  require grep -q -F -e 'benign-library' -- "$app/lib/$abi/libgtk.so"
  require test -L "$app/lib/$abi/internal-link"
  require test "$(readlink "$app/lib/$abi/internal-link")" = libgtk.so
  require test "$(readlink -m "$app/lib/$abi/internal-link")" = "$app/lib/$abi/libgtk.so"
  require regular_file "$app/share/glib-2.0/schemas/app.gschema.xml"
  require grep -q -F -e '<schema/>' -- "$app/share/glib-2.0/schemas/app.gschema.xml"
  require app_is_confined "$app" "$sysroot"
  require test "$(stage_status)" -eq 0
}

benign_arm64_library_and_schemas_are_staged() {
  prepare_case benign-arm64
  local tree archive pins sysroot app
  tree="$(mktemp -d)"
  write_benign_library "$tree" arm64-v8a
  archive="$work/gtk.pixie"
  pins="$work/pins.json"
  tar -C "$tree" -cJf "$archive" .
  rm -rf "$tree"
  pins_for arm64-v8a "$archive" "$pins"
  install_user "$pins"
  require test "$(cat "$work/install.status")" -eq 0
  sysroot="$(user_sysroot)"
  app="$work/app/.pixiewood/root"
  stage_into "$sysroot" "$app"
  expect_benign_staged "$app" arm64-v8a "$sysroot"
  require private_unchanged
}

benign_x86_64_library_is_staged() {
  prepare_case benign-x86
  local tree archive pins sysroot app
  tree="$(mktemp -d)"
  write_benign_library "$tree" x86_64
  archive="$work/gtk.pixie"
  pins="$work/pins.json"
  tar -C "$tree" -cJf "$archive" .
  rm -rf "$tree"
  pins_for x86_64 "$archive" "$pins"
  install_user "$pins" --abi x86_64
  require test "$(cat "$work/install.status")" -eq 0
  sysroot="$(user_sysroot)"
  app="$work/app/.pixiewood/root"
  stage_into "$sysroot" "$app"
  expect_benign_staged "$app" x86_64 "$sysroot"
  require is_known_abi x86_64
  require private_unchanged
}

# The archive's lib/<abi> entry is a symlink to the installing user's
# private directory. install unpacks it; stage-runtime must not follow it.
lib_symlink_is_not_followed_into_the_app_root() {
  prepare_case lib-symlink
  local tree archive pins sysroot app target resolved
  target="$(lib_symlink_target)"
  tree="$(mktemp -d)"
  mkdir -p "$tree/lib" "$tree/share/glib-2.0/schemas"
  ln -s "$target" "$tree/lib/arm64-v8a"
  printf '%s\n' '<schema/>' > "$tree/share/glib-2.0/schemas/app.gschema.xml"
  archive="$work/gtk.pixie"
  pins="$work/pins.json"
  tar -C "$tree" -cJf "$archive" .
  rm -rf "$tree"
  pins_for arm64-v8a "$archive" "$pins"
  install_user "$pins"
  sysroot="$(user_sysroot)"
  app="$work/a/b/c/d/e/f/app/.pixiewood/root"
  if [ -L "$sysroot/lib/arm64-v8a" ]; then
    resolved="$(readlink -f "$sysroot/lib/arm64-v8a")"
    require test "$resolved" = "$HOME/.ssh"
  fi
  if [ -f "$sysroot/share/pixiewood/MANIFEST.json" ]; then
    stage_into "$sysroot" "$app"
    if [ -e "$app" ]; then
      require app_is_confined "$app" "$sysroot"
    fi
    if [ -L "$sysroot/lib/arm64-v8a" ]; then
      require test "$(stage_status)" -ne 0
    fi
  fi
  require private_unchanged
}

schema_symlink_is_not_followed_into_the_app_root() {
  prepare_case schema-symlink
  local tree archive pins sysroot app target
  target="$(schema_symlink_target)"
  tree="$(mktemp -d)"
  write_benign_library "$tree" arm64-v8a
  rm -rf "$tree/share/glib-2.0/schemas"
  mkdir -p "$tree/share/glib-2.0"
  ln -s "$target" "$tree/share/glib-2.0/schemas"
  archive="$work/gtk.pixie"
  pins="$work/pins.json"
  tar -C "$tree" -cJf "$archive" .
  rm -rf "$tree"
  pins_for arm64-v8a "$archive" "$pins"
  install_user "$pins"
  sysroot="$(user_sysroot)"
  app="$work/app/.pixiewood/root"
  if [ -L "$sysroot/share/glib-2.0/schemas" ]; then
    require test "$(readlink -f "$sysroot/share/glib-2.0/schemas")" = "$HOME/.ssh"
  fi
  if [ -f "$sysroot/share/pixiewood/MANIFEST.json" ]; then
    stage_into "$sysroot" "$app"
    if [ -e "$app" ]; then
      require app_is_confined "$app" "$sysroot"
    fi
    if [ -L "$sysroot/share/glib-2.0/schemas" ]; then
      require test "$(stage_status)" -ne 0
    fi
  fi
  require private_unchanged
}

# lib itself is the symlink, so lib/$abi is outside even though the final
# component is a real directory.
ancestor_lib_symlink_is_not_followed() {
  prepare_case ancestor-lib
  local tree archive pins sysroot app target resolved=
  target="$(ancestor_symlink_target)"
  tree="$(mktemp -d)"
  ln -s "$target" "$tree/lib"
  mkdir -p "$tree/share/glib-2.0/schemas"
  printf '%s\n' '<schema/>' > "$tree/share/glib-2.0/schemas/app.gschema.xml"
  archive="$work/gtk.pixie"
  pins="$work/pins.json"
  tar -C "$tree" -cJf "$archive" .
  rm -rf "$tree"
  pins_for arm64-v8a "$archive" "$pins"
  install_user "$pins"
  sysroot="$(user_sysroot)"
  app="$work/app/.pixiewood/root"
  if [ -e "$sysroot/lib/arm64-v8a" ]; then
    resolved="$(readlink -f "$sysroot/lib/arm64-v8a")"
    require test "$resolved" = "$HOME/.ssh/arm64-v8a"
  fi
  if [ -f "$sysroot/share/pixiewood/MANIFEST.json" ]; then
    stage_into "$sysroot" "$app"
    if [ -e "$app" ]; then
      require app_is_confined "$app" "$sysroot"
    fi
    case "$resolved" in
      "$sysroot"/*) ;;
      "") ;;
      *) require test "$(stage_status)" -ne 0 ;;
    esac
  fi
  require private_unchanged
}

# A real library directory that contains links aimed outside the sysroot.
# Those links are skipped. Files and links that stay inside are copied.
symlinks_inside_the_library_are_not_staged_when_they_leave() {
  prepare_case nested-links
  local tree archive pins sysroot app rel abs
  rel="$(nested_symlink_target)"
  abs="$HOME/.ssh/marker.txt"
  tree="$(mktemp -d)"
  write_benign_library "$tree" arm64-v8a
  ln -s "$rel" "$tree/lib/arm64-v8a/rel-escape"
  ln -s "$abs" "$tree/lib/arm64-v8a/abs-escape"
  ln -s "$(rel_to "$HOME/.ssh" "$HOME/.local/lib/pixie/release/lib/arm64-v8a")" \
    "$tree/lib/arm64-v8a/dir-escape"
  archive="$work/gtk.pixie"
  pins="$work/pins.json"
  tar -C "$tree" -cJf "$archive" .
  rm -rf "$tree"
  pins_for arm64-v8a "$archive" "$pins"
  install_user "$pins"
  require test "$(cat "$work/install.status")" -eq 0
  sysroot="$(user_sysroot)"
  require test -L "$sysroot/lib/arm64-v8a/rel-escape"
  require test "$(readlink -f "$sysroot/lib/arm64-v8a/abs-escape")" = "$HOME/.ssh/marker.txt"
  app="$work/app/.pixiewood/root"
  stage_into "$sysroot" "$app"
  require test "$(stage_status)" -eq 0
  require regular_file "$app/lib/arm64-v8a/libgtk.so"
  require grep -q -F -e 'benign-library' -- "$app/lib/arm64-v8a/libgtk.so"
  require test -L "$app/lib/arm64-v8a/internal-link"
  require test ! -L "$app/lib/arm64-v8a/rel-escape"
  require test ! -e "$app/lib/arm64-v8a/rel-escape"
  require test ! -L "$app/lib/arm64-v8a/abs-escape"
  require test ! -e "$app/lib/arm64-v8a/abs-escape"
  require test ! -L "$app/lib/arm64-v8a/dir-escape"
  require test ! -e "$app/lib/arm64-v8a/dir-escape"
  require app_is_confined "$app" "$sysroot"
  require private_unchanged
}

# The pin's abi is joined onto lib/ and onto the app root. A value that
# leaves the sysroot must not be copied, and the destination must not be
# created outside the app root.
manifest_abi_that_leaves_the_sysroot_is_not_copied() {
  prepare_case abi-escape
  local tree archive pins sysroot app abi escaped
  tree="$(mktemp -d)"
  write_benign_library "$tree" arm64-v8a
  archive="$work/gtk.pixie"
  pins="$work/pins.json"
  tar -C "$tree" -cJf "$archive" .
  rm -rf "$tree"
  abi="$(rel_to "$HOME/.ssh" "$HOME/.local/lib/pixie/release/lib")"
  pins_for "$abi" "$archive" "$pins"
  install_user "$pins"
  sysroot="$(user_sysroot)"
  app="$work/a/b/c/d/e/f/app/.pixiewood/root"
  escaped="$(normpath "$app/lib/$abi")"
  case "$escaped" in
    "$work"/*) ;;
    *)
      echo "refusing to stage: escaped destination $escaped is outside $work" >&2
      return 1
      ;;
  esac
  require test "$(normpath "$sysroot/lib/$abi")" = "$HOME/.ssh"
  if [ -f "$sysroot/share/pixiewood/MANIFEST.json" ]; then
    abi="$(sysroot_json_get abi "$sysroot/share/pixiewood/MANIFEST.json")"
    stage_into "$sysroot" "$app"
    if [ -e "$escaped" ] && contains_marker "$escaped"; then
      return 1
    fi
    if [ -e "$app" ] && contains_marker "$app"; then
      return 1
    fi
    if ! is_known_abi "$abi"; then
      require test "$(stage_status)" -ne 0
      require test ! -e "$escaped"
    fi
  fi
  require test ! -e "$escaped"
  require private_unchanged
}

# activate uses the manifest abi in a wrapper path. An abi with extra
# segments must not create that file outside the sysroot.
activate_does_not_write_outside_the_sysroot_for_unconfined_abi() {
  prepare_case activate-escape
  local tree archive pins abi target sysroot wrapper
  tree="$(mktemp -d)"
  mkdir -p "$tree/include"
  printf '%s\n' 'header' > "$tree/include/only.h"
  archive="$work/gtk.pixie"
  pins="$work/pins.json"
  tar -C "$tree" -cJf "$archive" .
  rm -rf "$tree"
  target="$work/outside-activate/wrapper-out"
  sysroot="$HOME/.local/lib/pixie/release"
  abi="$(python3 - "$sysroot" "$target" << 'PY'
import os, sys
sysroot, target = sys.argv[1], sys.argv[2]
base = os.path.join(sysroot, "share/pixiewood/pkg-config-wrapper-x")
print("x/" + os.path.relpath(target, base))
PY
)"
  wrapper="$(normpath "$sysroot/share/pixiewood/pkg-config-wrapper-$abi")"
  [ "$wrapper" = "$target" ]
  case "$wrapper" in
    "$work"/*) ;;
    *)
      echo "refusing to install: wrapper path $wrapper is outside $work" >&2
      return 1
      ;;
  esac
  pins_for "$abi" "$archive" "$pins"
  install_user "$pins"
  require test ! -e "$target"
  require test ! -e "$work/outside-activate"
  require private_unchanged
}

# The library and schema directories are real while staging checks them.
# The copy tool then sees a symlink to the private directory. Following
# that symlink, or copying it into the app root, is a failure.
copy_does_not_follow_a_symlink_swapped_in_after_the_check() {
  prepare_case toctou
  local tree archive pins sysroot app private bindir
  private="$work/private"
  mkdir -p "$private"
  printf '%s\n' "$MARKER" > "$private/marker.txt"
  printf '%s\n' "$MARKER" > "$private/libgtk.so"
  printf '%s\n' "$MARKER" > "$private/app.gschema.xml"
  tree="$(mktemp -d)"
  write_benign_library "$tree" arm64-v8a
  archive="$work/gtk.pixie"
  pins="$work/pins.json"
  tar -C "$tree" -cJf "$archive" .
  rm -rf "$tree"
  pins_for arm64-v8a "$archive" "$pins"
  install_user "$pins"
  require test "$(cat "$work/install.status")" -eq 0
  sysroot="$(user_sysroot)"
  require test ! -L "$sysroot/lib/arm64-v8a"
  require test ! -L "$sysroot/share/glib-2.0/schemas"
  require regular_file "$sysroot/lib/arm64-v8a/libgtk.so"

  bindir="$work/bin"
  mkdir -p "$bindir"
  cat > "$bindir/cp" << 'EOF'
#!/bin/bash
log=$CP_LOG
private=$PRIVATE_DIR
swapped_one() {
  local dir=$1 arg
  [ -n "${dir}" ] || return 0
  [ -d "${dir}" ] || return 0
  [ -L "${dir}" ] && return 0
  for arg in "${args[@]}"; do
    case "${arg}" in
      "${dir}"|"${dir}/"|"${dir}/."|"${dir}"/*)
        rm -rf "${dir}"
        ln -s "${private}" "${dir}"
        printf 'swapped %s\n' "${dir}" >> "${log}"
        return 0
        ;;
    esac
  done
}
args=("$@")
swapped_one "${SRC_LIB:-}"
swapped_one "${SRC_SCHEMAS:-}"
exec /bin/cp "$@"
EOF
  chmod a+x "$bindir/cp"

  # The wrapper has to retarget the path cp actually receives, which is the
  # directory plus "/." . Prove that on a throwaway tree before staging.
  local probe src
  probe="$work/probe"
  src="$probe/src"
  mkdir -p "$src/keep" "$probe/dest"
  printf '%s\n' 'probe-benign' > "$src/keep/file"
  CP_LOG="$work/probe.log" \
    PRIVATE_DIR="$private" \
    SRC_LIB="$src/keep" \
    SRC_SCHEMAS="" \
    "$bindir/cp" -a "$src/keep/." "$probe/dest/"
  require test -L "$src/keep"
  require regular_file "$probe/dest/marker.txt"
  require grep -q -F -e "$MARKER" -- "$probe/dest/marker.txt"

  app="$work/app/.pixiewood/root"
  set +e
  CP_LOG="$work/cp.log" \
    PRIVATE_DIR="$private" \
    SRC_LIB="$sysroot/lib/arm64-v8a" \
    SRC_SCHEMAS="$sysroot/share/glib-2.0/schemas" \
    PATH="$bindir:$PATH" \
    "$STAGE" "$sysroot" "$app" >"$work/stage.out" 2>"$work/stage.err"
  printf '%s' $? > "$work/stage.status"
  set -e
  if [ -e "$app" ]; then
    if ! app_is_confined "$app" "$sysroot"; then
      echo "cp log:" >&2
      cat "$work/cp.log" >&2 || true
      return 1
    fi
  fi
  require private_unchanged
}

fail_count=0
run_case() {
  local name=$1 status
  shift
  echo "== $name =="
  # Errexit is off inside a function called from `if`, so run the case in
  # its own shell where a failed check stops that case.
  set +e
  (set -e; "$name")
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    echo "ok: $name"
  else
    echo "FAIL: $name" >&2
    fail_count=$((fail_count + 1))
  fi
}

run_case benign_arm64_library_and_schemas_are_staged
run_case benign_x86_64_library_is_staged
run_case lib_symlink_is_not_followed_into_the_app_root
run_case schema_symlink_is_not_followed_into_the_app_root
run_case ancestor_lib_symlink_is_not_followed
run_case symlinks_inside_the_library_are_not_staged_when_they_leave
run_case manifest_abi_that_leaves_the_sysroot_is_not_copied
run_case activate_does_not_write_outside_the_sysroot_for_unconfined_abi
run_case copy_does_not_follow_a_symlink_swapped_in_after_the_check

if [ "$fail_count" -ne 0 ]; then
  echo "stage runtime confine: $fail_count case(s) failed" >&2
  exit 1
fi
echo "stage runtime confine: ok"
