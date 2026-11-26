#!/usr/bin/env bash
# Symlinks shipped inside a .pixie archive must not receive the files
# pixie-pkg generates, and chmod of those paths must not change the
# symlink target. These checks fail until that is true.
#
# A write that looks the path up and then opens it by name is raced:
# tests/symlink-race-open.c replaces the name with a symlink on an open
# that does not fail for symlinks. Writing a new regular file and
# renaming it into place is not raced.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIXIE="$ROOT/scripts/pixie-pkg"
RACE_SRC="$ROOT/tests/symlink-race-open.c"
ABI=arm64-v8a
SENTINEL='sentinel-marker'
OLD_STAMP='2020-01-01 00:00:00 UTC'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME"

failures=0
WATCH_PATHS=()
WATCH_KINDS=()
WATCH_GOLD=()
WATCH_STAT=()
WATCH_DIRM=()

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

note_fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

normalize_path() {
  local path=$1 part
  local -a raw=() parts=()
  path=${path%/}
  local IFS=/
  read -r -a raw <<< "${path#/}"
  for part in "${raw[@]}"; do
    case "$part" in
      ''|.) ;;
      ..)
        if [ "${#parts[@]}" -gt 0 ]; then
          unset 'parts[-1]'
        fi
        ;;
      *) parts+=("$part") ;;
    esac
  done
  if [ "${#parts[@]}" -eq 0 ]; then
    printf '/\n'
    return
  fi
  local out="" p
  for p in "${parts[@]}"; do
    out="$out/$p"
  done
  printf '%s\n' "$out"
}

relative_link() {
  local from_dir target target_dir base cursor up rest
  from_dir="$(normalize_path "$1")"
  target="$(normalize_path "$2")"
  target_dir="$(normalize_path "$(dirname "$target")")"
  base="$(basename "$target")"
  cursor=$from_dir
  up=""
  while [ "$cursor" != / ] && [ "$target_dir" != "$cursor" ] &&
    [ "${target_dir#"$cursor"/}" = "$target_dir" ]; do
    cursor="$(dirname "$cursor")"
    up="${up}../"
  done
  if [ "$target_dir" = "$cursor" ]; then
    rest=""
  elif [ "$cursor" = / ]; then
    rest=${target_dir#/}
  else
    rest=${target_dir#"$cursor"/}
  fi
  if [ -n "$rest" ]; then
    printf '%s%s/%s\n' "$up" "$rest" "$base"
  elif [ -n "$up" ]; then
    printf '%s%s\n' "$up" "$base"
  else
    printf '%s\n' "$base"
  fi
}

check_relative_link() {
  local base=$tmp/relcheck
  mkdir -p "$base/a/b/c" "$base/a/z"
  printf '%s\n' marker > "$base/a/z/t"
  local rel
  rel="$(relative_link "$base/a/b/c" "$base/a/z/t")"
  ln -s "$rel" "$base/a/b/c/link"
  local got
  got="$(readlink -f "$base/a/b/c/link")"
  [ "$got" = "$base/a/z/t" ] || fail "relative_link resolved to $got"
  [ "$rel" = "../../z/t" ] || fail "relative_link returned $rel"
}

make_archive() {
  local dest=$1 link=${2:-} target=${3:-}
  local tree
  tree="$(mktemp -d)"
  mkdir -p "$tree/lib/$ABI/pkgconfig" \
    "$tree/lib/$ABI/gio/modules" \
    "$tree/bin/$ABI" \
    "$tree/share/pixiewood" \
    "$tree/share/glib-2.0"
  cat > "$tree/lib/$ABI/pkgconfig/gtk4.pc" << EOF
prefix=/
libdir=\${prefix}/lib/${ABI}
Name: gtk4
Version: 1
Libs: -L\${libdir} -lgtk4
EOF
  printf 'lib\n' > "$tree/lib/$ABI/libgtk4.so"
  printf 'archive\n' > "$tree/lib/$ABI/gio/modules/libgioopenssl.a"
  printf '#!/bin/sh\nexit 0\n' > "$tree/bin/$ABI/gdbus-codegen"
  chmod a+x "$tree/bin/$ABI/gdbus-codegen"
  if [ -n "$link" ]; then
    mkdir -p "$tree/$(dirname "$link")"
    ln -s "$target" "$tree/$link"
  fi
  tar -C "$tree" -cJf "$dest" .
  rm -rf "$tree"
}

write_pins() {
  local pins=$1 archive=$2
  jq -n --arg url "file://${archive}" '{
    packages: [
      {
        abi: "arm64-v8a",
        repo: "https://example.com/gtk.git",
        name: "gtk",
        track: "1",
        resolved: "abc",
        inputs: "def",
        url: $url
      }
    ]
  }' > "$pins"
}

clear_watch() {
  WATCH_PATHS=()
  WATCH_KINDS=()
  WATCH_GOLD=()
  WATCH_STAT=()
  WATCH_DIRM=()
}

watch_file() {
  local path=$1 mode=${2:-644} gold
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$SENTINEL" > "$path"
  chmod "$mode" "$path"
  touch -d "$OLD_STAMP" "$path" "$(dirname "$path")"
  gold="$tmp/gold/$(echo "$path" | tr '/' '_')"
  mkdir -p "$(dirname "$gold")"
  cp "$path" "$gold"
  WATCH_PATHS+=("$path")
  WATCH_KINDS+=("file")
  WATCH_GOLD+=("$gold")
  WATCH_STAT+=("$(stat -c '%i %Y %a' "$path")")
  WATCH_DIRM+=("")
}

watch_absent() {
  local path=$1
  mkdir -p "$(dirname "$path")"
  if [ -e "$path" ] || [ -L "$path" ]; then
    rm -f "$path"
  fi
  touch -d "$OLD_STAMP" "$(dirname "$path")"
  WATCH_PATHS+=("$path")
  WATCH_KINDS+=("absent")
  WATCH_GOLD+=("")
  WATCH_STAT+=("")
  WATCH_DIRM+=("$(stat -c %Y "$(dirname "$path")")")
}

watch_errors=0
watch_msg=()

check_watches() {
  local i path kind now nowd
  watch_errors=0
  watch_msg=()
  for i in "${!WATCH_PATHS[@]}"; do
    path=${WATCH_PATHS[$i]}
    kind=${WATCH_KINDS[$i]}
    if [ "$kind" = file ]; then
      if [ -L "$path" ] || [ ! -f "$path" ]; then
        watch_msg+=("$path is no longer a regular sentinel")
        watch_errors=$((watch_errors + 1))
        continue
      fi
      if ! cmp -s "$path" "${WATCH_GOLD[$i]}"; then
        watch_msg+=("$path content changed: $(head -c 60 "$path" | tr '\n' ' ')")
        watch_errors=$((watch_errors + 1))
      fi
      now="$(stat -c '%i %Y %a' "$path")"
      if [ "$now" != "${WATCH_STAT[$i]}" ]; then
        watch_msg+=("$path stat changed: $now != ${WATCH_STAT[$i]}")
        watch_errors=$((watch_errors + 1))
      fi
    else
      if [ -e "$path" ] || [ -L "$path" ]; then
        watch_msg+=("$path was created")
        watch_errors=$((watch_errors + 1))
      fi
      nowd="$(stat -c %Y "$(dirname "$path")")"
      if [ "$nowd" != "${WATCH_DIRM[$i]}" ]; then
        watch_msg+=("directory of $path changed mtime")
        watch_errors=$((watch_errors + 1))
      fi
    fi
  done
}

generated_ok() {
  local file=$1 kind=$2
  if [ -L "$file" ] || [ ! -f "$file" ]; then
    echo "$file is not a regular file"
    return 1
  fi
  case "$kind" in
    manifest)
      grep -q '"format": 1' "$file" || { echo "$file missing manifest"; return 1; }
      ;;
    index)
      grep -q '"packages"' "$file" || { echo "$file missing index"; return 1; }
      ;;
    wrapper|gdbus)
      [ -x "$file" ] || { echo "$file is not executable"; return 1; }
      [ "$(head -c 2 "$file")" = '#!' ] || { echo "$file is not a script"; return 1; }
      ;;
    cross)
      grep -q 'pkg-config' "$file" || { echo "$file missing cross file"; return 1; }
      ;;
    pulled)
      grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$file" || {
        echo "$file is not a timestamp"
        return 1
      }
      ;;
    gio)
      grep -q 'gioopenssl' "$file" || { echo "$file missing gioopenssl"; return 1; }
      ;;
    *)
      echo "unknown generated kind $kind"
      return 1
      ;;
  esac
}

# Run pixie-pkg. On success the generated path must be a regular file.
# Outside sentinels must be unchanged either way.
expect_contained() {
  local name=$1 root=$2 rel=$3 kind=$4
  shift 4
  local log=$tmp/logs/$name.log
  mkdir -p "$(dirname "$log")"
  set +e
  "$@" >"$log" 2>&1
  local status=$?
  set -e
  check_watches
  local problems=()
  if [ "$watch_errors" -ne 0 ]; then
    problems+=("${watch_msg[@]}")
  fi
  if [ "$status" -eq 0 ]; then
    local msg
    if ! msg="$(generated_ok "$root/$rel" "$kind")"; then
      problems+=("$msg")
    fi
  fi
  if [ "${#problems[@]}" -eq 0 ]; then
    echo "PASS $name (status $status)"
    return 0
  fi
  echo "FAIL $name (status $status)" >&2
  local line
  for line in "${problems[@]}"; do
    echo "  $line" >&2
  done
  failures=$((failures + 1))
}

install_root() {
  printf '%s\n' "$1/lib/pixie/release"
}

prepare_tree_case() {
  local case_dir=$1
  mkdir -p "$case_dir"
  clear_watch
}

benign_install() {
  local case_dir=$tmp/benign
  local archive=$case_dir/lib.pixie pins=$case_dir/pins.json
  local prefix=$case_dir/prefix root
  mkdir -p "$case_dir"
  make_archive "$archive"
  write_pins "$pins" "$archive"
  root="$(install_root "$prefix")"
  "$PIXIE" install --prefix "$prefix" --pins "$pins" >"$case_dir/log" 2>&1
  [ -f "$root/share/pixiewood/MANIFEST.json" ]
  [ ! -L "$root/share/pixiewood/MANIFEST.json" ]
  [ -f "$root/share/pixiewood/INDEX.json" ]
  [ ! -L "$root/share/pixiewood/pkg-config-wrapper" ]
  [ -x "$root/share/pixiewood/pkg-config-wrapper" ]
  [ -f "$root/share/pixiewood/pixie.cross" ]
  [ -f "$root/pulled" ]
  [ ! -L "$root/pulled" ]
  [ -f "$root/lib/$ABI/pkgconfig/gioopenssl.pc" ]
  [ -x "$root/share/pixiewood/gdbus-codegen" ]
  echo "PASS benign install"
}

# link_target is the symlink text stored in the archive.
archive_case() {
  local name=$1 command=$2 link=$3 link_target=$4 watch_path=$5 watch_kind=$6
  local gen_kind=$7
  local case_dir=$tmp/cases/$name
  local archive=$case_dir/lib.pixie pins=$case_dir/pins.json
  local prefix=$case_dir/prefix dest=$case_dir/fetched
  local home=$case_dir/home root
  prepare_tree_case "$case_dir"
  make_archive "$archive" "$link" "$link_target"
  write_pins "$pins" "$archive"
  if [ "$watch_kind" = absent ]; then
    watch_absent "$watch_path"
  else
    watch_file "$watch_path"
  fi
  case "$command" in
    install)
      root="$(install_root "$prefix")"
      expect_contained "$name" "$root" "$link" "$gen_kind" \
        "$PIXIE" install --prefix "$prefix" --pins "$pins"
      ;;
    pull)
      root="$(install_root "$prefix")"
      expect_contained "$name" "$root" "$link" "$gen_kind" \
        "$PIXIE" pull --force --prefix "$prefix" --pins "$pins"
      ;;
    fetch|latest)
      root=$dest
      expect_contained "$name" "$root" "$link" "$gen_kind" \
        "$PIXIE" "$command" --dest "$dest" --pins "$pins"
      ;;
    user)
      root=$home/.local/lib/pixie/release
      expect_contained "$name" "$root" "$link" "$gen_kind" \
        env HOME="$home" "$PIXIE" install --user --pins "$pins"
      ;;
    *)
      fail "unknown command $command"
      ;;
  esac
}

pull_then_apply() {
  local name=pull-apply-wrapper
  local case_dir=$tmp/cases/$name
  local archive=$case_dir/lib.pixie pins=$case_dir/pins.json
  local prefix=$case_dir/prefix
  local sentinel=$case_dir/outside/wrapper
  local root link log
  prepare_tree_case "$case_dir"
  watch_file "$sentinel"
  root="$(install_root "$prefix")"
  link=share/pixiewood/pkg-config-wrapper
  make_archive "$archive" "$link" "$sentinel"
  write_pins "$pins" "$archive"
  log=$tmp/logs/$name-pull.log
  mkdir -p "$(dirname "$log")"
  set +e
  "$PIXIE" pull --force --prefix "$prefix" --pins "$pins" >"$log" 2>&1
  local pull_status=$?
  local apply_status=0
  set -e
  if [ "$pull_status" -eq 0 ]; then
    set +e
    "$PIXIE" apply --prefix "$prefix" >"$tmp/logs/$name-apply.log" 2>&1
    apply_status=$?
    set -e
  fi
  check_watches
  local problems=()
  if [ "$watch_errors" -ne 0 ]; then
    problems+=("${watch_msg[@]}")
  fi
  if [ "$pull_status" -eq 0 ] && [ "$apply_status" -eq 0 ]; then
    local msg
    if ! msg="$(generated_ok "$root/$link" wrapper)"; then
      problems+=("$msg")
    fi
  fi
  if [ "${#problems[@]}" -eq 0 ]; then
    echo "PASS $name (pull $pull_status apply $apply_status)"
    return 0
  fi
  echo "FAIL $name (pull $pull_status apply $apply_status)" >&2
  local line
  for line in "${problems[@]}"; do
    echo "  $line" >&2
  done
  failures=$((failures + 1))
}

race_case() {
  local name=$1 base=$2 link=$3 kind=$4
  local case_dir=$tmp/cases/$name
  local archive=$case_dir/lib.pixie pins=$case_dir/pins.json
  local prefix=$case_dir/prefix
  local race_dir=$case_dir/outside
  local ready=$case_dir/ready
  local sentinel=$race_dir/$base
  local root so
  prepare_tree_case "$case_dir"
  make_archive "$archive"
  write_pins "$pins" "$archive"
  watch_file "$sentinel"
  root="$(install_root "$prefix")"
  so=$tmp/raceopen.so
  if [ ! -f "$so" ]; then
    gcc -shared -fPIC -O2 -Wall -Werror -o "$so" "$RACE_SRC"
  fi
  rm -f "$ready"
  expect_contained "$name" "$root" "$link" "$kind" \
    env LD_PRELOAD="$so" \
      PIXIE_RACE_DIR="$race_dir" \
      PIXIE_RACE_NAME="$base" \
      PIXIE_RACE_READY="$ready" \
      "$PIXIE" install --prefix "$prefix" --pins "$pins"
  if [ ! -s "$ready" ]; then
    note_fail "$name: race preload did not run"
  fi
}

check_relative_link
benign_install

archive_symlink() {
  local name=$1 command=$2 link=$3 kind=$4 watch_kind=${5:-file}
  local case_dir=$tmp/cases/$name
  local sentinel=$case_dir/outside/target
  rm -rf "$case_dir"
  archive_case "$name" "$command" "$link" "$sentinel" "$sentinel" "$watch_kind" "$kind"
}

archive_relative() {
  local name=$1 command=$2 link=$3 kind=$4 root_for_link=$5
  local case_dir=$tmp/cases/$name
  local sentinel=$case_dir/outside/target
  local from_dir rel
  rm -rf "$case_dir"
  from_dir="$(normalize_path "$root_for_link/$(dirname "$link")")"
  rel="$(relative_link "$from_dir" "$sentinel")"
  archive_case "$name" "$command" "$link" "$rel" "$sentinel" file "$kind"
}

archive_symlink install-manifest install share/pixiewood/MANIFEST.json manifest
archive_symlink install-index install share/pixiewood/INDEX.json index
archive_symlink install-wrapper install share/pixiewood/pkg-config-wrapper wrapper
archive_symlink install-cross install share/pixiewood/pixie.cross cross
archive_symlink install-wrapper-abi install \
  "share/pixiewood/pkg-config-wrapper-$ABI" wrapper
archive_symlink install-cross-abi install \
  "share/pixiewood/pixie-$ABI.cross" cross
archive_symlink install-pulled install pulled pulled
archive_symlink install-gio install "lib/$ABI/pkgconfig/gioopenssl.pc" gio
archive_symlink install-gdbus install share/pixiewood/gdbus-codegen gdbus
archive_symlink install-wrapper-create install \
  share/pixiewood/pkg-config-wrapper wrapper absent

archive_symlink pull-manifest pull share/pixiewood/MANIFEST.json manifest
archive_symlink pull-index pull share/pixiewood/INDEX.json index
archive_symlink pull-pulled pull pulled pulled
archive_symlink pull-gio pull "lib/$ABI/pkgconfig/gioopenssl.pc" gio

archive_symlink fetch-manifest fetch share/pixiewood/MANIFEST.json manifest
archive_symlink fetch-wrapper fetch share/pixiewood/pkg-config-wrapper wrapper
archive_symlink fetch-cross fetch share/pixiewood/pixie.cross cross
archive_symlink fetch-gdbus fetch share/pixiewood/gdbus-codegen gdbus
archive_symlink latest-index latest share/pixiewood/INDEX.json index

archive_at() {
  local name=$1 command=$2 link=$3 kind=$4 sentinel=$5 watch_kind=${6:-file}
  rm -rf "$tmp/cases/$name"
  archive_case "$name" "$command" "$link" "$sentinel" "$sentinel" "$watch_kind" "$kind"
}

archive_at user-profile user share/pixiewood/MANIFEST.json manifest \
  "$tmp/cases/user-profile/home/.profile"
archive_at user-keys user share/pixiewood/pkg-config-wrapper wrapper \
  "$tmp/cases/user-keys/home/.ssh/authorized_keys" absent

# Relative targets that leave the final tree. Seal runs in a temp staging
# directory for install and pull, so a relative manifest is only asserted
# for fetch, which seals in the destination. pulled and the activation
# files are written after the tree is in its final directory.
rel_root_install() {
  printf '%s\n' "$tmp/cases/$1/prefix/lib/pixie/release"
}
rel_root_fetch() {
  printf '%s\n' "$tmp/cases/$1/fetched"
}

archive_relative install-pulled-rel install pulled pulled \
  "$(rel_root_install install-pulled-rel)"
archive_relative install-wrapper-rel install \
  share/pixiewood/pkg-config-wrapper wrapper \
  "$(rel_root_install install-wrapper-rel)"
archive_relative install-cross-rel install share/pixiewood/pixie.cross cross \
  "$(rel_root_install install-cross-rel)"
archive_relative fetch-manifest-rel fetch share/pixiewood/MANIFEST.json manifest \
  "$(rel_root_fetch fetch-manifest-rel)"
archive_relative fetch-gio-rel fetch "lib/$ABI/pkgconfig/gioopenssl.pc" gio \
  "$(rel_root_fetch fetch-gio-rel)"

pull_then_apply

race_case race-manifest MANIFEST.json share/pixiewood/MANIFEST.json manifest
race_case race-index INDEX.json share/pixiewood/INDEX.json index
race_case race-wrapper pkg-config-wrapper share/pixiewood/pkg-config-wrapper wrapper
race_case race-cross pixie.cross share/pixiewood/pixie.cross cross
race_case race-wrapper-abi "pkg-config-wrapper-$ABI" \
  "share/pixiewood/pkg-config-wrapper-$ABI" wrapper
race_case race-cross-abi "pixie-$ABI.cross" \
  "share/pixiewood/pixie-$ABI.cross" cross
race_case race-pulled pulled pulled pulled
race_case race-gio gioopenssl.pc "lib/$ABI/pkgconfig/gioopenssl.pc" gio
race_case race-gdbus gdbus-codegen share/pixiewood/gdbus-codegen gdbus

if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all activation symlink checks passed"
