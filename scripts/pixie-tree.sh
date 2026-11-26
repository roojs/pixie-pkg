#!/usr/bin/env bash
# Pack (finalize) or activate a pixiewood Android sysroot tree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pixie-common.sh
source "$ROOT/pixie-common.sh"

TOKEN='@PIXIEWOOD_SYSROOT@'

usage() {
  echo "Usage: $0 finalize --destdir DIR --version VER --abi ABI --arch ARCH --api N --ndk VER --pixiewood-revision REV --gtk-target NAME --gtk-url URL --gtk-revision REV --provided FILE --java-glue DIR" >&2
  echo "       $0 seal --destdir DIR --version VER --abi ABI --arch ARCH --api N --ndk VER --pixiewood-revision REV --gtk-target NAME --gtk-url URL --gtk-revision REV --provided FILE" >&2
  echo "       $0 pack-fragment --destdir DIR --abi ABI --tarball PATH [--java-glue DIR]" >&2
  echo "       $0 activate SYSROOT" >&2
  exit 2
}

pc_field() {
  local file=$1 key=$2
  sed -n "s/^${key}:[[:space:]]*//p" "$file" | head -n1 | tr -d '\r'
}

write_gioopenssl_pc() {
  local destdir=$1 abi=$2 archive
  sysroot_check_abi "$abi" || exit 1
  archive="$destdir/lib/$abi/gio/modules/libgioopenssl.a"
  [ -f "$archive" ] || return 0
  # glib-networking's generated .pc describes the shared GIO module.
  # Apps link the static archive and call g_io_openssl_load().
  sysroot_write "$destdir" "lib/$abi/pkgconfig" gioopenssl.pc file << EOF
prefix=/
libdir=\${prefix}/lib/${abi}

Name: gioopenssl
Description: Static GIO OpenSSL TLS backend
Version: 2.80.1
Requires: gio-2.0
Requires.private: libssl libcrypto
Libs: \${libdir}/gio/modules/libgioopenssl.a
Cflags:
EOF
}

write_manifest() {
  local destdir=$1 version=$2 abi=$3 arch=$4 api=$5 ndk=$6
  local pixiewood_rev=$7 gtk_target=$8 gtk_url=$9 gtk_revision=${10} provided=${11}
  sysroot_check_abi "$abi" || exit 1
  local pkgconfig="$destdir/lib/$abi/pkgconfig"
  local manifest="$destdir/share/pixiewood/MANIFEST.json"
  local -a names=()
  local line name version_pc pc base count first content

  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    names+=("$line")
  done < "$provided"
  if [ "${#names[@]}" -eq 0 ]; then
    echo "No provided dependencies in $provided" >&2
    exit 1
  fi

  content="$(mktemp)"
  {
    printf '{\n'
    printf '  "format": 1,\n'
    printf '  "name": "pixiewood-android-sysroot",\n'
    printf '  "version": "%s",\n' "$(sysroot_json_escape "$version")"
    printf '  "abi": "%s",\n' "$(sysroot_json_escape "$abi")"
    printf '  "arch": "%s",\n' "$(sysroot_json_escape "$arch")"
    printf '  "api": %s,\n' "$api"
    printf '  "ndk": "%s",\n' "$(sysroot_json_escape "$ndk")"
    printf '  "pixiewood_revision": "%s",\n' "$(sysroot_json_escape "$pixiewood_rev")"
    printf '  "gtk_target": "%s",\n' "$(sysroot_json_escape "$gtk_target")"
    printf '  "gtk_url": "%s",\n' "$(sysroot_json_escape "$gtk_url")"
    printf '  "gtk_revision": "%s",\n' "$(sysroot_json_escape "$gtk_revision")"
    printf '  "pkgconfig_dir": "%s",\n' "$(sysroot_json_escape "lib/$abi/pkgconfig")"
    printf '  "java_glue": "share/pixiewood/gtk-android-java",\n'
    printf '  "prefix_token": "%s",\n' "$TOKEN"
    printf '  "provided_dependencies": ['
    first=1
    for name in "${names[@]}"; do
      if [ "$first" -eq 1 ]; then
        first=0
      else
        printf ', '
      fi
      printf '"%s"' "$(sysroot_json_escape "$name")"
    done
    printf '],\n'
    printf '  "components": [\n'
    count=0
    first=1
    if [ -d "$pkgconfig" ]; then
      while IFS= read -r pc; do
        [ -n "$pc" ] || continue
        base="$(basename "$pc" .pc)"
        name="$(pc_field "$pc" Name)"
        [ -n "$name" ] || name="$base"
        version_pc="$(pc_field "$pc" Version)"
        if [ "$first" -eq 1 ]; then
          first=0
        else
          printf ',\n'
        fi
        printf '    {"pc": "%s", "name": "%s", "version": "%s"}' \
          "$(sysroot_json_escape "$base")" \
          "$(sysroot_json_escape "$name")" \
          "$(sysroot_json_escape "$version_pc")"
        count=$((count + 1))
      done < <(find "$pkgconfig" -name '*.pc' -type f | sort)
    fi
    if [ "$first" -eq 0 ]; then
      printf '\n'
    fi
    printf '  ],\n'
    printf '  "activated_prefix": null\n'
    printf '}\n'
  } > "$content"
  if ! sysroot_write "$destdir" share/pixiewood MANIFEST.json file < "$content"; then
    rm -f "$content"
    exit 1
  fi
  rm -f "$content"
  echo "Wrote $manifest ($count pkg-config files)"
}

read_meta_args() {
  destdir=
  version=
  abi=
  arch=
  api=
  ndk=
  pixiewood_rev=
  gtk_target=
  gtk_url=
  gtk_revision=
  provided=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --destdir) destdir=$2; shift 2 ;;
      --version) version=$2; shift 2 ;;
      --abi) abi=$2; shift 2 ;;
      --arch) arch=$2; shift 2 ;;
      --api) api=$2; shift 2 ;;
      --ndk) ndk=$2; shift 2 ;;
      --pixiewood-revision) pixiewood_rev=$2; shift 2 ;;
      --gtk-target) gtk_target=$2; shift 2 ;;
      --gtk-url) gtk_url=$2; shift 2 ;;
      --gtk-revision) gtk_revision=$2; shift 2 ;;
      --provided) provided=$2; shift 2 ;;
      *) echo "Unknown argument: $1" >&2; usage ;;
    esac
  done
  for value in "$destdir" "$version" "$abi" "$arch" "$api" "$ndk" \
    "$pixiewood_rev" "$gtk_target" "$gtk_url" "$gtk_revision" "$provided"; do
    if [ -z "$value" ]; then
      usage
    fi
  done
  sysroot_check_abi "$abi" || exit 1
  if [ ! -d "$destdir" ]; then
    echo "Destdir missing: $destdir" >&2
    exit 1
  fi
  destdir="$(cd "$destdir" && pwd)"
}

cmd_finalize() {
  local destdir version abi arch api ndk pixiewood_rev gtk_target gtk_url gtk_revision provided java_glue
  java_glue=
  local -a meta=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --java-glue) java_glue=$2; shift 2 ;;
      *) meta+=("$1"); shift ;;
    esac
  done
  read_meta_args "${meta[@]}"
  if [ -z "$java_glue" ] || [ ! -d "$java_glue" ]; then
    echo "Java glue directory missing: $java_glue" >&2
    exit 1
  fi
  java_glue="$(cd "$java_glue" && pwd)"
  write_gioopenssl_pc "$destdir" "$abi"
  sysroot_rewrite_prefix '/' "$TOKEN" "$destdir"
  mkdir -p "$destdir/share/pixiewood/gtk-android-java"
  cp -a "$java_glue/." "$destdir/share/pixiewood/gtk-android-java/"
  write_manifest "$destdir" "$version" "$abi" "$arch" "$api" "$ndk" \
    "$pixiewood_rev" "$gtk_target" "$gtk_url" "$gtk_revision" "$provided"
}

cmd_seal() {
  local destdir version abi arch api ndk pixiewood_rev gtk_target gtk_url gtk_revision provided
  read_meta_args "$@"
  local libdir
  if [ -d "$destdir/lib" ]; then
    for libdir in "$destdir"/lib/*; do
      [ -d "$libdir" ] || continue
      write_gioopenssl_pc "$destdir" "$(basename "$libdir")"
    done
  else
    write_gioopenssl_pc "$destdir" "$abi"
  fi
  sysroot_rewrite_prefix '/' "$TOKEN" "$destdir"
  write_manifest "$destdir" "$version" "$abi" "$arch" "$api" "$ndk" \
    "$pixiewood_rev" "$gtk_target" "$gtk_url" "$gtk_revision" "$provided"
}

cmd_pack_fragment() {
  local destdir= abi= tarball= java_glue=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --destdir) destdir=$2; shift 2 ;;
      --abi) abi=$2; shift 2 ;;
      --tarball) tarball=$2; shift 2 ;;
      --java-glue) java_glue=$2; shift 2 ;;
      *) echo "Unknown argument: $1" >&2; usage ;;
    esac
  done
  if [ -z "$destdir" ] || [ -z "$abi" ] || [ -z "$tarball" ]; then
    usage
  fi
  sysroot_check_abi "$abi" || exit 1
  if [ ! -d "$destdir" ]; then
    echo "Destdir missing: $destdir" >&2
    exit 1
  fi
  destdir="$(cd "$destdir" && pwd)"
  write_gioopenssl_pc "$destdir" "$abi"
  if [ -n "$java_glue" ]; then
    if [ ! -d "$java_glue" ]; then
      echo "Java glue directory missing: $java_glue" >&2
      exit 1
    fi
    mkdir -p "$destdir/share/pixiewood/gtk-android-java"
    cp -a "$java_glue/." "$destdir/share/pixiewood/gtk-android-java/"
  fi
  rm -f "$destdir/share/pixiewood/MANIFEST.json" \
    "$destdir/share/pixiewood/INDEX.json" \
    "$destdir/share/pixiewood/pixie.cross" \
    "$destdir/share/pixiewood/pkg-config-wrapper"
  sysroot_rewrite_prefix '/' "$TOKEN" "$destdir"
  mkdir -p "$(dirname "$tarball")"
  tar -C "$destdir" -cJf "$tarball" .
  echo "Wrote $tarball"
}

sh_single_quote() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

is_script() {
  [ -f "$1" ] && [ "$(head -c 2 "$1")" = '#!' ]
}

# Write share/pixiewood/NAME in SYSROOT.
write_wrapper() {
  local sysroot=$1 name=$2 pkgconfig=$3
  sysroot_write "$sysroot" share/pixiewood "$name" exec << EOF
#!/bin/sh
# Meson sets PKG_CONFIG_SYSROOT_DIR from the NDK sysroot.
# These .pc files already use absolute paths in the pixiewood sysroot.
unset PKG_CONFIG_SYSROOT_DIR
export PKG_CONFIG_LIBDIR=$(sh_single_quote "$pkgconfig")
export PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1
export PKG_CONFIG_ALLOW_SYSTEM_LIBS=1
exec pkg-config "\$@"
EOF
}

meson_quote() {
  local s=$1
  s=${s//\'/\\\'}
  printf "'%s'" "$s"
}

# gdbus-codegen is installed in bin/$abi. Its own lookup only treats a
# directory named bin as the prefix, then falls back to the baked datadir
# /share. The modules are in share/glib-2.0/codegen. A shell wrapper puts
# that directory on PYTHONPATH; the script's failed lookup does not remove it.
write_gdbus_codegen_launch() {
  local sysroot=$1 abi=$2
  local script="$sysroot/bin/$abi/gdbus-codegen"
  local codegen="$sysroot/share/glib-2.0"
  sysroot_write "$sysroot" share/pixiewood gdbus-codegen exec << EOF
#!/bin/sh
export PYTHONPATH=$(sh_single_quote "$codegen")\${PYTHONPATH:+:\$PYTHONPATH}
exec $(sh_single_quote "$script") "\$@"
EOF
}

# Write share/pixiewood/NAME in SYSROOT. WRAPPER names the pkg-config wrapper
# in that same directory.
write_cross() {
  local sysroot=$1 abi=$2 wrapper=$3 name=$4
  local pkgconfig="$sysroot/lib/$abi/pkgconfig"
  local tool script launch=
  if is_script "$sysroot/bin/$abi/gdbus-codegen"; then
    write_gdbus_codegen_launch "$sysroot" "$abi"
    launch="$sysroot/share/pixiewood/gdbus-codegen"
  fi
  {
    printf '[binaries]\n'
    printf 'pkg-config = [%s]\n' "$(meson_quote "$sysroot/share/pixiewood/$wrapper")"
    for tool in glib-mkenums glib-genmarshal gdbus-codegen; do
      script="$sysroot/bin/$abi/$tool"
      # Installed GLib tools are scripts. Run them through their shebang.
      if [ "$tool" = gdbus-codegen ] && [ -n "$launch" ]; then
        printf '%s = [%s]\n' "$tool" "$(meson_quote "$launch")"
      elif is_script "$script"; then
        printf '%s = [%s]\n' "$tool" "$(meson_quote "$script")"
      fi
    done
    printf '\n[properties]\n'
    printf 'pkg_config_libdir = [%s]\n' "$(meson_quote "$pkgconfig")"
  } | sysroot_write "$sysroot" share/pixiewood "$name" file
}

cmd_activate() {
  local sysroot=${1:-}
  [ -n "$sysroot" ] || usage
  sysroot="$(cd "$sysroot" && pwd)"
  local manifest="$sysroot/share/pixiewood/MANIFEST.json"
  if [ ! -f "$manifest" ] || [ -L "$manifest" ]; then
    echo "Sysroot manifest missing: $manifest" >&2
    exit 1
  fi
  local format abi token previous target pkgconfig
  format="$(sysroot_json_get format "$manifest")"
  if [ "$format" != 1 ]; then
    echo "Unsupported sysroot format: $format" >&2
    exit 1
  fi
  abi="$(sysroot_json_get abi "$manifest")"
  sysroot_check_abi "$abi" || exit 1
  token="$(sysroot_json_get prefix_token "$manifest")"
  [ -n "$token" ] || token=$TOKEN
  previous="$(sysroot_json_get activated_prefix "$manifest")"
  target=$sysroot
  pkgconfig="$sysroot/lib/$abi/pkgconfig"
  if [ "$previous" = "$target" ] && ! sysroot_pc_contains "$pkgconfig" "$token"; then
    :
  else
    sysroot_rewrite_prefix "$token" "$target" "$sysroot"
    if [ -n "$previous" ] && [ "$previous" != "$target" ]; then
      sysroot_rewrite_prefix "$previous" "$target" "$sysroot"
    fi
  fi
  local -a abis=()
  local libdir base selected have=0
  if [ -d "$sysroot/lib" ]; then
    for libdir in "$sysroot"/lib/*; do
      [ -d "$libdir/pkgconfig" ] || continue
      base="$(basename "$libdir")"
      sysroot_check_abi "$base" || exit 1
      abis+=("$base")
    done
  fi
  if [ "${#abis[@]}" -eq 0 ]; then
    abis=("$abi")
  fi
  selected="$abi"
  if [ -n "${PIXIE_ABI:-}" ]; then
    selected="$PIXIE_ABI"
  fi
  for base in "${abis[@]}"; do
    if [ "$base" = "$selected" ]; then
      have=1
    fi
  done
  if [ "$have" -eq 0 ]; then
    selected="${abis[0]}"
  fi
  for base in "${abis[@]}"; do
    write_wrapper "$sysroot" "pkg-config-wrapper-$base" "$sysroot/lib/$base/pkgconfig"
    write_cross "$sysroot" "$base" "pkg-config-wrapper-$base" "pixie-$base.cross"
    if [ "$base" = "$selected" ]; then
      write_wrapper "$sysroot" pkg-config-wrapper "$sysroot/lib/$base/pkgconfig"
      write_cross "$sysroot" "$base" pkg-config-wrapper pixie.cross
    fi
  done
  sysroot_set_activated_prefix "$sysroot" "$target"
  echo "Activated $sysroot"
  echo "Meson cross file: $sysroot/share/pixiewood/pixie.cross"
}

command=${1:-}
shift || usage
case "$command" in
  finalize) cmd_finalize "$@" ;;
  seal) cmd_seal "$@" ;;
  pack-fragment) cmd_pack_fragment "$@" ;;
  activate) cmd_activate "$@" ;;
  *) usage ;;
esac
