#!/usr/bin/env bash
# Copy sysroot libraries and GSettings schemas into a Pixiewood install root.
#
# Pixiewood's meson install only packages the application. Shared libraries
# that came from pkg-config are not copied unless this step puts them
# in .pixiewood/root before Gradle runs.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 SYSROOT PIXIEWOOD_ROOT" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pixie-common.sh
source "$ROOT/pixie-common.sh"

sysroot="$(cd -P "$1" && pwd -P)"
mkdir -p "$2"
root="$(cd "$2" && pwd)"
manifest="$sysroot/share/pixiewood/MANIFEST.json"

if [ ! -f "$manifest" ]; then
  echo "Pixie manifest missing: $manifest" >&2
  echo "Unpack the pixie libraries and run pixie-pkg apply." >&2
  exit 1
fi

abi="$(sysroot_json_get abi "$manifest")"
if ! sysroot_valid_abi "$abi"; then
  echo "Unsupported ABI in $manifest: $abi" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
work="$(cd -P "$work" && pwd -P)"

# Copy SYSROOT/REL into WORK/REL. The directory is entered once and its real
# path is checked from inside it, so a symlink swapped in later is not read.
# tar walks the tree from there without following symlinks.
# Exit status 3 means the directory is absent.
collect() {
  local rel=$1
  (
    if ! cd -P -- "$sysroot/$rel" 2>/dev/null; then
      if [ -e "$sysroot/$rel" ] || [ -L "$sysroot/$rel" ]; then
        echo "Refusing to stage $sysroot/$rel: it is not a directory" >&2
        exit 1
      fi
      exit 3
    fi
    if [ "$(pwd -P 2>/dev/null)" != "$sysroot/$rel" ]; then
      echo "Refusing to stage $sysroot/$rel: it is reached through a symlink" >&2
      exit 1
    fi
    mkdir -p "$work/$rel"
    tar -cf - . | tar -C "$work/$rel" -xpf -
  )
}

inside_work() {
  case "$1" in
    "$work"|"$work"/*) return 0 ;;
  esac
  return 1
}

# Drop copied symlinks whose target leaves the staged tree, read both as
# written and with every link on the way resolved.
drop_escaping_links() {
  local link target lexical real dropped=1
  while [ "$dropped" -eq 1 ]; do
    dropped=0
    while IFS= read -r -d '' link; do
      target="$(readlink -- "$link")"
      case "$target" in
        /*) lexical="$(realpath -m -s -- "$target")" ;;
        *) lexical="$(realpath -m -s -- "$(dirname -- "$link")/$target")" ;;
      esac
      real="$(realpath -m -- "$link")"
      if inside_work "$lexical" && inside_work "$real"; then
        continue
      fi
      echo "Skipping ${link#"$work"/}: its target is outside the sysroot" >&2
      rm -f -- "$link"
      dropped=1
    done < <(find -P "$work" -type l -print0)
  done
}

members=("lib/$abi")
status=0
collect "lib/$abi" || status=$?
if [ "$status" -eq 3 ]; then
  echo "Pixie library directory missing: $sysroot/lib/$abi" >&2
  exit 1
elif [ "$status" -ne 0 ]; then
  exit "$status"
fi

status=0
collect share/glib-2.0/schemas || status=$?
if [ "$status" -eq 0 ]; then
  members+=(share/glib-2.0/schemas)
elif [ "$status" -ne 3 ]; then
  exit "$status"
fi

drop_escaping_links
tar -C "$work" -cf - "${members[@]}" | tar -C "$root" -xpf -

echo "Staged $abi runtime into $root"
