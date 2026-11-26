#!/usr/bin/env bash
# The pin-list abi is copied into the sysroot manifest and then used as a
# path segment for the pkg-config wrapper and the Meson cross file.
# A value with parent-directory segments, or a final path that resolves
# through a symlink, must be rejected before any file outside the sysroot
# is created or replaced.
#
# These tests fail while that still happens.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIXIE="$ROOT/scripts/pixie-pkg"
STAGE="$ROOT/scripts/stage-runtime.sh"

if [ "$#" -gt 1 ]; then
  echo "Usage: $0 [case]" >&2
  exit 2
fi
only=${1:-all}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME"

want() {
  [ "$only" = all ] || [ "$only" = "$1" ]
}

ups() {
  local n=$1 i
  local out=
  for ((i = 0; i < n; i++)); do
    out+="../"
  done
  printf '%s' "$out"
}

# Enough parent segments to reach / from the sysroot, then the absolute target.
# The wrapper name is "pkg-config-wrapper-" glued to the first segment, so the
# extra climbs cancel that directory and still land on the target.
traversal_abi() {
  local target=$1
  local rel=${target#/}
  printf '%s%s' "$(ups 48)" "$rel"
}

new_canaries() {
  local dir=$1
  mkdir -p "$dir"
  printf 'CANARY-WRAPPER\n' > "$dir/pwned"
  printf 'CANARY-CROSS\n' > "$dir/pwned.cross"
  chmod 644 "$dir/pwned" "$dir/pwned.cross"
}

snapshot_canaries() {
  local dir=$1 snap=$2
  mkdir -p "$snap"
  cp "$dir/pwned" "$dir/pwned.cross" "$snap/"
  stat -c '%a %Y' "$dir/pwned" > "$snap/pwned.meta"
  stat -c '%a %Y' "$dir/pwned.cross" > "$snap/pwned.cross.meta"
}

check_canaries() {
  local dir=$1 snap=$2 label=$3
  local file meta now
  for file in pwned pwned.cross; do
    if ! cmp -s "$dir/$file" "$snap/$file"; then
      echo "$label: $dir/$file was replaced" >&2
      exit 1
    fi
    meta="$(cat "$snap/$file.meta")"
    now="$(stat -c '%a %Y' "$dir/$file")"
    if [ "$now" != "$meta" ]; then
      echo "$label: $dir/$file metadata changed ($meta -> $now)" >&2
      exit 1
    fi
  done
}

last_ec=0
run_capture() {
  local out="$tmp/run.out" err="$tmp/run.err"
  set +e
  "$@" >"$out" 2>"$err"
  last_ec=$?
  set -e
}

# Archive with no lib/*/pkgconfig. The pixie-.. directory is the first
# component of the cross-file path ("pixie-" glued to "..").
traversal_archive() {
  local dest=$1 tree
  tree="$(mktemp -d)"
  mkdir -p "$tree/share/pixiewood/pixie-.."
  printf 'dummy\n' > "$tree/README"
  tar -C "$tree" -cJf "$dest" .
  rm -rf "$tree"
}

pins_for() {
  local abi=$1 archive=$2 dest=$3
  jq -n --arg abi "$abi" --arg url "file://${archive}" '{
    packages: [
      {
        abi: $abi,
        repo: "https://example.com/gtk.git",
        name: "gtk",
        track: "1",
        resolved: "abc",
        inputs: "def",
        url: $url
      }
    ]
  }' > "$dest"
}

assert_lands_on() {
  local path=$1 target=$2 label=$3
  local got
  got="$(realpath -m "$path")"
  if [ "$got" != "$target" ]; then
    echo "$label: $path resolves to $got, wanted $target" >&2
    exit 1
  fi
}

# fetch, install, apply, and latest all activate. The abi is not arm64-v8a,
# and the archive has no package-config directory, so activation uses the
# abi text as the wrapper file name.
activation_case() {
  local label=$1
  shift
  local work="$tmp/work-$label"
  rm -rf "$work"
  mkdir -p "$work"
  local outside="$work/outside"
  local snap="$work/snap"
  new_canaries "$outside"
  snapshot_canaries "$outside" "$snap"
  local archive="$work/empty.pixie"
  traversal_archive "$archive"
  local abi
  abi="$(traversal_abi "$outside/pwned")"
  local pins="$work/pins.json"
  pins_for "$abi" "$archive" "$pins"
  local sysroot=$1
  shift
  assert_lands_on "$sysroot/share/pixiewood/pkg-config-wrapper-$abi" \
    "$outside/pwned" "$label wrapper"
  assert_lands_on "$sysroot/share/pixiewood/pixie-$abi.cross" \
    "$outside/pwned.cross" "$label cross"
  run_capture "$@"
  check_canaries "$outside" "$snap" "$label"
  if [ "$last_ec" -eq 0 ]; then
    echo "$label: command succeeded" >&2
    cat "$tmp/run.err" >&2
    exit 1
  fi
}

if want fetch; then
  activation_case fetch "$tmp/fetch-dest" \
    "$PIXIE" fetch --dest "$tmp/fetch-dest" --pins "$tmp/work-fetch/pins.json"
fi

if want latest; then
  activation_case latest "$tmp/latest-dest" \
    "$PIXIE" latest --dest "$tmp/latest-dest" --pins "$tmp/work-latest/pins.json"
fi

if want install-prefix; then
  activation_case install-prefix "$tmp/prefix/lib/pixie/release" \
    "$PIXIE" install --prefix "$tmp/prefix" --pins "$tmp/work-install-prefix/pins.json"
fi

if want install-user; then
  activation_case install-user "$HOME/.local/lib/pixie/release" \
    "$PIXIE" install --user --pins "$tmp/work-install-user/pins.json"
fi

if want install-abi-flag; then
  # --abi is not checked against data/abi. An unknown value is kept and
  # becomes the manifest abi.
  work="$tmp/work-install-abi-flag"
  rm -rf "$work"
  mkdir -p "$work"
  outside="$work/outside"
  new_canaries "$outside"
  snapshot_canaries "$outside" "$work/snap"
  archive="$work/empty.pixie"
  traversal_archive "$archive"
  abi="$(traversal_abi "$outside/pwned")"
  pins_for "$abi" "$archive" "$work/pins.json"
  sysroot="$tmp/abi-prefix/lib/pixie/release"
  assert_lands_on "$sysroot/share/pixiewood/pkg-config-wrapper-$abi" \
    "$outside/pwned" "install-abi-flag wrapper"
  assert_lands_on "$sysroot/share/pixiewood/pixie-$abi.cross" \
    "$outside/pwned.cross" "install-abi-flag cross"
  run_capture "$PIXIE" install --prefix "$tmp/abi-prefix" \
    --pins "$work/pins.json" --abi "$abi"
  check_canaries "$outside" "$work/snap" install-abi-flag
  if [ "$last_ec" -eq 0 ]; then
    echo "install-abi-flag: command succeeded" >&2
    cat "$tmp/run.err" >&2
    exit 1
  fi
fi

if want apply; then
  # pull stores the abi and does not activate. apply activates that tree.
  work="$tmp/work-apply"
  rm -rf "$work"
  mkdir -p "$work"
  outside="$work/outside"
  new_canaries "$outside"
  snapshot_canaries "$outside" "$work/snap"
  archive="$work/empty.pixie"
  traversal_archive "$archive"
  abi="$(traversal_abi "$outside/pwned")"
  pins_for "$abi" "$archive" "$work/pins.json"
  sysroot="$tmp/apply-prefix/lib/pixie/release"
  assert_lands_on "$sysroot/share/pixiewood/pkg-config-wrapper-$abi" \
    "$outside/pwned" "apply wrapper"
  assert_lands_on "$sysroot/share/pixiewood/pixie-$abi.cross" \
    "$outside/pwned.cross" "apply cross"
  set +e
  "$PIXIE" pull --prefix "$tmp/apply-prefix" --pins "$work/pins.json" \
    >"$work/pull.out" 2>"$work/pull.err"
  pull_ec=$?
  "$PIXIE" apply --prefix "$tmp/apply-prefix" \
    >"$work/apply.out" 2>"$work/apply.err"
  apply_ec=$?
  set -e
  check_canaries "$outside" "$work/snap" apply
  if [ "$pull_ec" -eq 0 ] && [ "$apply_ec" -eq 0 ]; then
    echo "apply: pull and apply both succeeded" >&2
    cat "$work/pull.err" "$work/apply.err" >&2
    exit 1
  fi
  if [ "$apply_ec" -eq 0 ]; then
    echo "apply: activation succeeded" >&2
    cat "$work/apply.err" >&2
    exit 1
  fi
fi

if want published-list; then
  # install with no --pins reads the published list. The body is the same
  # pin file the other cases pass with --pins; curl is used only to return
  # that body for the documented Pages URL. Archive bytes still go through
  # the real curl.
  work="$tmp/work-published-list"
  rm -rf "$work"
  mkdir -p "$work/pages" "$work/bin"
  outside="$work/outside"
  new_canaries "$outside"
  snapshot_canaries "$outside" "$work/snap"
  archive="$work/empty.pixie"
  traversal_archive "$archive"
  abi="$(traversal_abi "$outside/pwned")"
  pins_for "$abi" "$archive" "$work/pages/release.pins"
  sysroot="$tmp/published-prefix/lib/pixie/release"
  assert_lands_on "$sysroot/share/pixiewood/pkg-config-wrapper-$abi" \
    "$outside/pwned" "published-list wrapper"
  real_curl="$(command -v curl)"
  cat > "$work/bin/curl" << EOF
#!/usr/bin/env bash
set -euo pipefail
url=""
dest=""
prev=""
for arg in "\$@"; do
  if [ "\$prev" = "-o" ]; then
    dest=\$arg
    prev=""
    continue
  fi
  case "\$arg" in
    -o) prev=-o ;;
    http://*|https://*|file://*) url=\$arg ;;
  esac
done
case "\$url" in
  https://roojs.github.io/pixiewood-pkgs/*.pins|https://raw.githubusercontent.com/*/*/*.pins)
    cp "$work/pages/\${url##*/}" "\$dest"
    ;;
  *)
    exec "$real_curl" "\$@"
    ;;
esac
EOF
  chmod +x "$work/bin/curl"
  run_capture env PATH="$work/bin:$PATH" "$PIXIE" install --prefix "$tmp/published-prefix"
  check_canaries "$outside" "$work/snap" published-list
  if [ "$last_ec" -eq 0 ]; then
    echo "published-list: command succeeded" >&2
    cat "$tmp/run.err" >&2
    exit 1
  fi
fi

if want symlink-wrapper; then
  # The abi is a single safe segment. The archive plants the wrapper and
  # cross-file names as symlinks to files outside the sysroot. A check of
  # the path text, or of only its parent directory, still opens those names.
  work="$tmp/work-symlink-wrapper"
  rm -rf "$work"
  mkdir -p "$work"
  outside="$work/outside"
  new_canaries "$outside"
  snapshot_canaries "$outside" "$work/snap"
  tree="$work/tree"
  mkdir -p "$tree/share/pixiewood"
  ln -s "$outside/pwned" "$tree/share/pixiewood/pkg-config-wrapper-arm64-v8a"
  ln -s "$outside/pwned.cross" "$tree/share/pixiewood/pixie-arm64-v8a.cross"
  printf 'dummy\n' > "$tree/README"
  archive="$work/linked.pixie"
  tar -C "$tree" -cJf "$archive" .
  pins_for "arm64-v8a" "$archive" "$work/pins.json"
  run_capture "$PIXIE" fetch --dest "$work/dest" --pins "$work/pins.json"
  check_canaries "$outside" "$work/snap" symlink-wrapper
  if [ "$last_ec" -eq 0 ]; then
    echo "symlink-wrapper: command succeeded" >&2
    cat "$tmp/run.err" >&2
    exit 1
  fi
fi

# stage-runtime joins the same manifest abi under the install root.
# The directory depths differ, so one relative abi is a real library
# directory and also a path outside the root the caller passed.
stage_escape_abi() {
  local sysroot=$1 src=$2
  mkdir -p "$sysroot/lib" "$src"
  realpath --relative-to "$sysroot/lib" "$src"
}

stage_app_for() {
  local sysroot=$1 src=$2 abi=$3
  local depth app dest
  for depth in 1 2 3 4 5 6 7 8 9 10; do
    app="$tmp/stage-app"
    local i
    for ((i = 0; i < depth; i++)); do
      app="$app/d"
    done
    dest="$(realpath -m "$app/lib/$abi")"
    case "$dest" in
      "$tmp"/*) ;;
      *) continue ;;
    esac
    case "$dest" in
      "$app"|"$app"/*|"$sysroot"|"$sysroot"/*|"$src"|"$src"/*) continue ;;
    esac
    printf '%s\n' "$app"
    return 0
  done
  echo "no install root makes the abi leave that root" >&2
  return 1
}

if want stage-direct; then
  work="$tmp/work-stage-direct"
  rm -rf "$work"
  sysroot="$work/sysroot"
  src="$work/srcdir"
  mkdir -p "$sysroot/share/pixiewood" "$src"
  printf 'SECRET\n' > "$src/marker.txt"
  abi="$(stage_escape_abi "$sysroot" "$src")"
  app="$(stage_app_for "$sysroot" "$src" "$abi")"
  dest="$(realpath -m "$app/lib/$abi")"
  cat > "$sysroot/share/pixiewood/MANIFEST.json" << EOF
{
  "format": 1,
  "abi": "$abi",
  "prefix_token": "@PIXIEWOOD_SYSROOT@",
  "activated_prefix": null
}
EOF
  run_capture "$STAGE" "$sysroot" "$app"
  if [ -e "$dest" ]; then
    echo "stage-direct: created $dest" >&2
    exit 1
  fi
  if [ "$last_ec" -eq 0 ]; then
    echo "stage-direct: command succeeded" >&2
    cat "$tmp/run.err" >&2
    exit 1
  fi
  if ! cmp -s "$src/marker.txt" <(printf 'SECRET\n'); then
    echo "stage-direct: source marker changed" >&2
    exit 1
  fi
fi

if want stage-pull; then
  work="$tmp/work-stage-pull"
  rm -rf "$work"
  prefix="$work/prefix"
  sysroot="$prefix/lib/pixie/release"
  src="$work/srcdir"
  mkdir -p "$src"
  printf 'SECRET\n' > "$src/marker.txt"
  # The lib directory has to exist or the joined ".." path does not resolve.
  # It must not contain a pkgconfig directory.
  mkdir -p "$sysroot/lib"
  abi="$(stage_escape_abi "$sysroot" "$src")"
  app="$(stage_app_for "$sysroot" "$src" "$abi")"
  dest="$(realpath -m "$app/lib/$abi")"
  tree="$work/tree"
  mkdir -p "$tree/lib"
  printf 'dummy\n' > "$tree/README"
  archive="$work/dir.pixie"
  tar -C "$tree" -cJf "$archive" .
  pins_for "$abi" "$archive" "$work/pins.json"
  set +e
  "$PIXIE" pull --prefix "$prefix" --pins "$work/pins.json" \
    >"$work/pull.out" 2>"$work/pull.err"
  pull_ec=$?
  stage_ec=1
  if [ -f "$sysroot/share/pixiewood/MANIFEST.json" ]; then
    "$STAGE" "$sysroot" "$app" >"$work/stage.out" 2>"$work/stage.err"
    stage_ec=$?
  fi
  set -e
  if [ -e "$dest" ]; then
    echo "stage-pull: created $dest" >&2
    exit 1
  fi
  if [ "$pull_ec" -eq 0 ] && [ "$stage_ec" -eq 0 ]; then
    echo "stage-pull: pull and stage-runtime both succeeded" >&2
    exit 1
  fi
fi

echo "abi path: ok"
