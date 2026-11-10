#!/usr/bin/env bash
# Prove the checkout's package from the published pins.
# Every library before it is a published package. This command does not
# edit wraps and does not name those libraries.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 << 'EOF'
Usage: pixie-pkg prove --tag TAG --out DIR

Run this from the package checkout. The tag is the revision to compile.
Every library before that package is taken from the published pins.
A release pin is used when its version is one this checkout accepts.
A library with no release pin uses its snapshot pin.
The command stops when a library would have to be compiled.
EOF
  exit 2
}

tag=""
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag) tag=${2:-}; [ -n "$tag" ] || usage; shift 2 ;;
    --out) out=${2:-}; [ -n "$out" ] || usage; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done
[ -n "$tag" ] && [ -n "$out" ] || usage

case "$tag" in
  *-pixie) ;;
  *)
    echo "Tag $tag does not end in -pixie" >&2
    exit 2
    ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  echo "pixie-pkg needs jq" >&2
  exit 1
fi

declare -A major_of=() minor_of=() min_of=() max_of=()
declare -A cmin=() cmax=()

version_lt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

version_ge() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

record_constraint() {
  local pkg=$1 min=$2 max=$3
  if [ -n "$min" ]; then
    if [ -z "${cmin[$pkg]:-}" ] || version_lt "${cmin[$pkg]}" "$min"; then
      cmin[$pkg]=$min
    fi
  fi
  if [ -n "$max" ]; then
    if [ -z "${cmax[$pkg]:-}" ] || version_lt "$max" "${cmax[$pkg]}"; then
      cmax[$pkg]=$max
    fi
  fi
}

# Minima come from *_req. A ceiling comes from VERSION_MAX_ALLOWED.
# dependency() lines attach those limits to the names the checkout asks for.
parse_constraints() {
  local file=$1 line prefix add
  local re_major=$'^([A-Za-z0-9_]+)_major_req[[:space:]]*=[[:space:]]*([0-9]+)'
  local re_minor=$'^([A-Za-z0-9_]+)_minor_req[[:space:]]*=[[:space:]]*([0-9]+)'
  local re_min=$'^([A-Za-z0-9_]+)_req[[:space:]]*=[[:space:]]*\'>=[[:space:]]*([0-9][0-9.]*)\''
  local re_min_fmt=$'^([A-Za-z0-9_]+)_req[[:space:]]*=[[:space:]]*\'>=[[:space:]]*@0@\\.@1@\'\\.format\\(([A-Za-z0-9_]+)_major_req,[[:space:]]*([A-Za-z0-9_]+)_minor_req\\)'
  local re_max='format\(([A-Za-z0-9_]+)_major_req,[[:space:]]*([A-Za-z0-9_]+)_minor_req[[:space:]]*(\+[[:space:]]*([0-9]+))?\)'
  local re_dep='dependency\('"'"'([^'"'"']+)'"'"'[^)]*version:[[:space:]]*([A-Za-z0-9_]+)_req'
  local re_dep_lit='dependency\('"'"'([^'"'"']+)'"'"'[^)]*version:[[:space:]]*'"'"'>=[[:space:]]*([0-9][0-9.]*)'"'"
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ $re_major ]]; then
      major_of[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
    fi
    if [[ $line =~ $re_minor ]]; then
      minor_of[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
    fi
    if [[ $line =~ $re_min ]]; then
      min_of[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
    elif [[ $line =~ $re_min_fmt ]]; then
      prefix=${BASH_REMATCH[1]}
      if [ "${BASH_REMATCH[2]}" = "$prefix" ] && [ "${BASH_REMATCH[3]}" = "$prefix" ] \
        && [ -n "${major_of[$prefix]:-}" ] && [ -n "${minor_of[$prefix]:-}" ]; then
        min_of[$prefix]="${major_of[$prefix]}.${minor_of[$prefix]}"
      fi
    fi
    if [[ $line == *VERSION_MAX_ALLOWED* && $line =~ $re_max ]]; then
      prefix=${BASH_REMATCH[1]}
      if [ "$prefix" = "${BASH_REMATCH[2]}" ] \
        && [ -n "${major_of[$prefix]:-}" ] && [ -n "${minor_of[$prefix]:-}" ]; then
        add=${BASH_REMATCH[4]:-0}
        max_of[$prefix]="${major_of[$prefix]}.$((minor_of[$prefix] + add + 1))"
      fi
    fi
    if [[ $line =~ $re_dep ]]; then
      prefix=${BASH_REMATCH[2]}
      record_constraint "${BASH_REMATCH[1]}" "${min_of[$prefix]:-}" "${max_of[$prefix]:-}"
    elif [[ $line =~ $re_dep_lit ]]; then
      record_constraint "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" ""
    fi
  done < "$file"
}

# Release numbers only. A branch or a commit is not a version.
track_version() {
  local track=$1 base version
  case "$track" in
    main|master|HEAD|head|trunk|snapshot) return 0 ;;
  esac
  base=$track
  base=${base%.tar.gz}
  base=${base%.tar.xz}
  base=${base%.tar.bz2}
  base=${base%.tgz}
  base=${base%.zip}
  if [[ $base =~ (^|[-_])([vV]?[0-9]+([.][0-9]+)*)$ ]]; then
    version=${BASH_REMATCH[2]}
    version=${version#v}
    version=${version#V}
    printf '%s\n' "$version"
  fi
}

# Names this wrap provides. The checkout's dependency() lines use those names.
provide_names() {
  local wrap=$1
  [ -f "$wrap" ] || return 0
  awk '
    /^\[provide\]/ { on = 1; next }
    /^\[/ { on = 0 }
    on && /=/ {
      key = $1
      if (key == "dependency_names") {
        line = $0
        sub(/^[^=]*=[[:space:]]*/, "", line)
        n = split(line, parts, /[,[:space:]]+/)
        for (i = 1; i <= n; i++) if (parts[i] != "") print parts[i]
      } else {
        print key
      }
    }
  ' "$wrap"
}

pin_acceptable() {
  local track=$1 ver name min max
  shift
  ver="$(track_version "$track")"
  # A branch or a commit is the published package. A release version has to
  # sit inside every limit this checkout states for the names it provides.
  if [ -z "$ver" ]; then
    return 0
  fi
  for name in "$@"; do
    [ -n "$name" ] || continue
    min=${cmin[$name]:-}
    max=${cmax[$name]:-}
    if [ -n "$min" ] && ! version_ge "$ver" "$min"; then
      return 1
    fi
    if [ -n "$max" ] && ! version_lt "$ver" "$max"; then
      return 1
    fi
  done
  return 0
}

pin_row() {
  local file=$1 abi=$2 name=$3
  [ -f "$file" ] || return 1
  jq -c --arg abi "$abi" --arg name "$name" '
    .packages[]
    | select(.abi == $abi and .name == $name and (.url // "") != "")
  ' "$file" | head -n1
}

checkout_root() {
  local root
  if [ -f meson.build ]; then
    pwd
    return 0
  fi
  if root="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -f "$root/meson.build" ]; then
    printf '%s\n' "$root"
    return 0
  fi
  echo "Run pixie-pkg prove from the package checkout." >&2
  return 1
}

owner_of() {
  local url=$1 normalized owner
  normalized=$url
  case "$normalized" in
    *://*) ;;
    *:*) normalized="ssh://${normalized%%:*}/${normalized#*:}" ;;
  esac
  normalized=${normalized%.git}
  owner="$(printf '%s\n' "$normalized" | sed -n 's#^.*/\([^/][^/]*\)/[^/][^/]*$#\1#p')"
  if [ -z "$owner" ]; then
    echo "Cannot read the repo owner from $url" >&2
    return 1
  fi
  printf '%s\n' "$owner"
}

root="$(checkout_root)"
version="$(sed -n "s/.*version: '\\([0-9][0-9.]*\\)'.*/\\1/p" "$root/meson.build" | head -n1)"
if [ -z "$version" ]; then
  echo "Could not read the version from meson.build" >&2
  exit 1
fi
project="$(sed -n "s/^project('\\([^']*\\)'.*/\\1/p" "$root/meson.build" | head -n1)"
if [ -z "$project" ]; then
  echo "Could not read the project name from meson.build" >&2
  exit 1
fi
parse_constraints "$root/meson.build"

remote="$(git -C "$root" remote get-url origin)"
owner="$(owner_of "$remote")"
target="${owner}.${tag}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pkgs="$work/pkgs"
if [ -n "${PIXIE_SRC:-}" ]; then
  mkdir -p "$pkgs"
  cp -a "${PIXIE_SRC}/." "$pkgs/"
else
  repo="${PIXIE_REPO:-roojs/pixiewood-pkgs}"
  branch="${PIXIE_BRANCH:-main}"
  case "$repo" in
    *://*) url=$repo ;;
    *) url="https://github.com/${repo}.git" ;;
  esac
  git clone --depth 1 --branch "$branch" "$url" "$pkgs"
fi

order="$pkgs/build-order.txt"
if [ ! -f "$order" ]; then
  echo "Build order is missing from the package checkout" >&2
  exit 1
fi
abi="$(awk '$1 == "aarch64" { print $2; exit }' "$pkgs/cross/abi")"
if [ -z "$abi" ]; then
  echo "Could not read the aarch64 ABI" >&2
  exit 1
fi

targets="$pkgs/packages/gtk/targets"
if [ ! -f "$targets" ]; then
  echo "GTK target list is missing" >&2
  exit 1
fi
if ! grep -q "^${target} " "$targets"; then
  printf '%s %s %s -\n' "$target" "$remote" "$tag" >> "$targets"
fi

if ! deps_text="$(awk -v leaf="$project" '
  /^[[:space:]]*($|#)/ { next }
  {
    name = $1
    sub(/#.*/, "", name)
    gsub(/^[ \t]+|[ \t]+$/, "", name)
  }
  name == leaf { found = 1; exit }
  name != "" { print name }
  END { if (!found) exit 1 }
' "$order")"; then
  echo "Build order has no $project" >&2
  exit 1
fi
mapfile -t deps <<< "$deps_text"
if [ "${#deps[@]}" -eq 1 ] && [ -z "${deps[0]}" ]; then
  deps=()
fi

deps_json="$work/deps.pins"
printf '%s\n' '{"packages":[]}' > "$deps_json"
for name in "${deps[@]}"; do
  names=()
  while IFS= read -r provided; do
    [ -n "$provided" ] || continue
    names+=("$provided")
  done < <(provide_names "$pkgs/packages/$name/$name.wrap")
  if [ "${#names[@]}" -eq 0 ]; then
    names+=("$name")
  fi
  chosen=""
  from=""
  for from in "$pkgs/release.pins" "$pkgs/snapshot.pins"; do
    row="$(pin_row "$from" "$abi" "$name" || true)"
    [ -n "$row" ] || continue
    track="$(printf '%s\n' "$row" | jq -r '.track')"
    if pin_acceptable "$track" "${names[@]}"; then
      chosen=$row
      break
    fi
  done
  if [ -z "$chosen" ]; then
    echo "dependency would be compiled: $name" >&2
    exit 1
  fi
  track="$(printf '%s\n' "$chosen" | jq -r '.track')"
  echo "Using published $name $track"
  tmp="$(mktemp)"
  jq --argjson row "$chosen" '.packages += [$row]' "$deps_json" > "$tmp"
  mv "$tmp" "$deps_json"
done

if [ "${PIXIE_SKIP_HOST_SETUP:-}" != 1 ]; then
  "$pkgs/scripts/ci-host-setup.sh"
fi

deps_root="$work/deps"
mkdir -p "$deps_root"
"$HERE/pixie-pkg" fetch --dest "$deps_root" --pins "$deps_json" --abi "$abi" >/dev/null

tarball="$work/${project}.tar.xz"
(
  cd "$pkgs"
  scripts/build-pixie.sh \
    --only "$project" \
    --arch aarch64 \
    --gtk "$target" \
    --deps-sysroot "$deps_root" \
    --tarball "$tarball"
)

mkdir -p "$out"
out="$(cd "$out" && pwd)"
cp -a "$tarball" "$out/${project}-arm-v31-${version}.pixie"
echo "Pixie package is $out/${project}-arm-v31-${version}.pixie"
