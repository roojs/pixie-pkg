#!/usr/bin/env bash
# install, pull, and apply against a local pin file. No network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIXIE="$ROOT/scripts/pixie"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME"

make_pixie() {
  local abi=$1 name=$2 dest=$3 tree
  tree="$(mktemp -d)"
  mkdir -p "$tree/lib/$abi/pkgconfig"
  cat > "$tree/lib/$abi/pkgconfig/${name}.pc" << EOF
prefix=/
libdir=\${prefix}/lib/${abi}
Name: ${name}
Version: 1
Libs: -L\${libdir} -l${name}
EOF
  printf '%s\n' "$name" > "$tree/lib/$abi/lib${name}.so"
  tar -C "$tree" -cJf "$dest" .
  rm -rf "$tree"
}

arm="$tmp/gtk-arm.pixie"
x86="$tmp/gtk-x86.pixie"
extra="$tmp/extra-arm.pixie"
make_pixie arm64-v8a gtk4 "$arm"
make_pixie x86_64 gtk4 "$x86"
make_pixie arm64-v8a extra "$extra"

repo=https://gitlab.gnome.org/GNOME/gtk.git
pins="$tmp/release.pins"
jq -n \
  --arg repo "$repo" \
  --arg arm "file://${arm}" \
  --arg x86 "file://${x86}" \
  --arg extra "file://${extra}" \
  '{
    packages: [
      {abi:"x86_64", repo:$repo, name:"gtk", track:"4.18.0", resolved:"abc", inputs:"def", url:$x86},
      {abi:"arm64-v8a", repo:$repo, name:"extra", track:"9", resolved:"eee", inputs:"fff", url:$extra},
      {abi:"arm64-v8a", repo:$repo, name:"gtk", track:"4.18.0", resolved:"abc", inputs:"def", url:$arm}
    ]
  }' > "$pins"

prefix="$tmp/usr"
out="$("$PIXIE" install --prefix "$prefix" --pins "$pins")"
dir="$prefix/lib/pixie/release"
[ "$out" = "$dir" ]
test -f "$dir/pulled"
grep -F -x "prefix=$dir" "$dir/lib/arm64-v8a/pkgconfig/gtk4.pc"
grep -F -x "prefix=$dir" "$dir/lib/x86_64/pkgconfig/gtk4.pc"
test -f "$dir/lib/arm64-v8a/pkgconfig/extra.pc"
test -f "$dir/share/pixiewood/pixie.cross"
test -f "$dir/share/pixiewood/pixie-arm64-v8a.cross"
test -f "$dir/share/pixiewood/pixie-x86_64.cross"
grep -q '"name": "gtk"' "$dir/share/pixiewood/INDEX.json"
grep -q '"name": "extra"' "$dir/share/pixiewood/INDEX.json"
# build-order.txt lists gtk before a name that is not in the list,
# and extra is still present. openssl is absent from this pin file.
jq -e '.packages | length == 3' "$dir/share/pixiewood/INDEX.json" >/dev/null

# A fresh pull does not download again.
mv "$arm" "$arm.away"
mv "$x86" "$x86.away"
mv "$extra" "$extra.away"
stderr="$("$PIXIE" pull --prefix "$prefix" --pins "$pins" 2>&1 >/dev/null)"
printf '%s\n' "$stderr" | grep -q 'current'
mv "$arm.away" "$arm"
mv "$x86.away" "$x86"
mv "$extra.away" "$extra"

applied="$("$PIXIE" apply --prefix "$prefix")"
[ "$applied" = "$dir" ]
printf '%s\n' "$applied" | grep -q '/lib/pixie/release$'

# Older than 24 hours: apply stops. pull --force replaces the set.
printf '%s\n' '2020-01-01T00:00:00Z' > "$dir/pulled"
if "$PIXIE" apply --prefix "$prefix" --system >/dev/null 2>"$tmp/stale"; then
  echo "apply used a stale set" >&2
  exit 1
fi
grep -q 'older than 24 hours' "$tmp/stale"
forced="$("$PIXIE" pull --prefix "$prefix" --pins "$pins" --force)"
[ "$forced" = "$dir" ]
[ "$(tr -d '[:space:]' < "$dir/pulled")" != "2020-01-01T00:00:00Z" ]

# One ABI.
abi_prefix="$tmp/abi"
"$PIXIE" install --prefix "$abi_prefix" --pins "$pins" --abi x86_64 >/dev/null
test -d "$abi_prefix/lib/pixie/release/lib/x86_64"
if [ -d "$abi_prefix/lib/pixie/release/lib/arm64-v8a" ]; then
  echo "arm libraries were installed with --abi x86_64" >&2
  exit 1
fi

# Snapshot is a different directory. A user install uses ~/.local.
snap="$tmp/snapshot.pins"
cp "$pins" "$snap"
user_out="$("$PIXIE" install --user --snapshot --pins "$snap")"
[ "$user_out" = "$HOME/.local/lib/pixie/snapshot" ]
test ! -d "$HOME/.local/lib/pixie/release"
find "$HOME/.cache/pixie/snapshot" -name '*.pixie' | grep -q .

# fetch unpacks into the directory it was given.
fetch_dest="$tmp/fetch"
fetched="$("$PIXIE" fetch --dest "$fetch_dest" --pins "$pins" --abi arm64-v8a)"
[ "$fetched" = "$fetch_dest" ]
grep -F -x "prefix=$fetch_dest" "$fetch_dest/lib/arm64-v8a/pkgconfig/gtk4.pc"
test ! -f "$fetch_dest/pulled"

bad="$tmp/bad.pins"
jq -n --arg url "file://${arm}" '{
  packages: [
    {abi:"arm64-v8a", repo:"https://example.com/a.git", name:"gtk", track:"1", resolved:"a", inputs:"b", url:$url},
    {abi:"arm64-v8a", repo:"https://example.com/b.git", name:"gtk", track:"1", resolved:"c", inputs:"d", url:$url}
  ]
}' > "$bad"
if "$PIXIE" install --prefix "$tmp/bad-prefix" --pins "$bad" >/dev/null 2>"$tmp/bad.err"; then
  echo "two gtk checkouts were accepted" >&2
  exit 1
fi
grep -q 'more than one gtk' "$tmp/bad.err"

echo "pixie command: ok"
