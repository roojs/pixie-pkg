# Shared helpers for the sysroot scripts. Source this file; do not execute it.

sysroot_json_escape() {
  local s=$1 i c out
  out=
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      '\\') out+='\\' ;;
      '"') out+='\"' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      *) out+=$c ;;
    esac
  done
  printf '%s' "$out"
}

# Print the string or number stored at "key". null prints an empty string.
# Returns 1 when the key is absent.
sysroot_json_get() {
  local key=$1 file=$2 value
  if ! value="$(awk -v key="$key" '
    function extract(line,    re, s, i, c, out, esc) {
      re = "\"" key "\"[[:space:]]*:[[:space:]]*"
      if (line !~ re) return 0
      if (match(line, re "null")) {
        print ""
        return 1
      }
      if (line ~ re "-?[0-9]+" && line !~ re "\"") {
        if (match(line, re "-?[0-9]+")) {
          s = substr(line, RSTART, RLENGTH)
          sub(/^.*:[[:space:]]*/, "", s)
          print s
          return 1
        }
      }
      if (!match(line, re "\"")) return 0
      s = substr(line, RSTART + RLENGTH)
      out = ""
      esc = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (esc) {
          if (c == "n") out = out "\n"
          else if (c == "r") out = out "\r"
          else if (c == "t") out = out "\t"
          else out = out c
          esc = 0
        } else if (c == "\\") esc = 1
        else if (c == "\"") {
          print out
          return 1
        } else out = out c
      }
      return 0
    }
    { if (extract($0)) { ok = 1; exit } }
    END { if (!ok) exit 1 }
  ' "$file")"; then
    echo "JSON file $file has no \"$key\"" >&2
    return 1
  fi
  printf '%s' "$value"
}

# Write stdin to DEST, then apply MODE (chmod syntax) when given.
# DEST is never opened: the data goes to a new file in a fresh private
# directory next to it, which is renamed over DEST. A symlink or hard link
# already at DEST is replaced, not written through.
sysroot_write_file() {
  local dest=$1 mode=${2:-} tmpdir
  tmpdir="$(mktemp -d "$(dirname "$dest")/.pixie-write.XXXXXXXX")" || return 1
  if cat > "$tmpdir/new" &&
    { [ -z "$mode" ] || chmod "$mode" "$tmpdir/new"; } &&
    mv -fT "$tmpdir/new" "$dest"; then
    rmdir "$tmpdir"
    return 0
  fi
  rm -rf "$tmpdir"
  return 1
}

# Succeeds when symlink text TARGET, read from directory DIR (relative to
# the tree root), names a path inside the tree without leaving it on the way.
sysroot_link_inside() {
  local dir=$1 target=$2 part depth=0
  local -a parts=()
  case "$target" in
    ''|/*) return 1 ;;
  esac
  local IFS=/
  read -r -d '' -a parts < <(printf '%s' "$dir") || true
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.) ;;
      ..) return 1 ;;
      *) depth=$((depth + 1)) ;;
    esac
  done
  parts=()
  read -r -d '' -a parts < <(printf '%s' "$target") || true
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.) ;;
      ..)
        depth=$((depth - 1))
        [ "$depth" -ge 0 ] || return 1
        ;;
      *) depth=$((depth + 1)) ;;
    esac
  done
}

# Refuse a tree that holds a symlink leaving it, or a symlink to a directory.
# With no directory symlinks, ".." in a link target is resolved exactly as
# written, so every remaining link stays inside the tree wherever it is moved.
sysroot_check_tree() {
  local root=$1 link rel target
  [ -d "$root" ] || return 0
  while IFS= read -r -d '' link; do
    rel=${link#"$root"/}
    target="$(readlink -- "$link"; printf x)"
    target=${target%x}
    target=${target%$'\n'}
    if [ -d "$link" ] || ! sysroot_link_inside "$(dirname -- "$rel")" "$target"; then
      echo "Refusing symlink in $root: $rel -> $target" >&2
      echo "Symlinks must stay inside the tree and must not name a directory." >&2
      return 1
    fi
  done < <(find -H "$root" -type l -print0)
}

sysroot_set_activated_prefix() {
  local file=$1 prefix=$2 escaped
  escaped="$(sysroot_json_escape "$prefix")"
  ESCAPED="$escaped" awk '
    function replace_prefix(line, prefix,    re, pre, rest, i, c, esc) {
      re = "\"activated_prefix\"[[:space:]]*:[[:space:]]*"
      if (match(line, re "null")) {
        pre = substr(line, 1, RSTART - 1)
        rest = substr(line, RSTART + RLENGTH)
        return pre "\"activated_prefix\": \"" prefix "\"" rest
      }
      if (match(line, re "\"")) {
        pre = substr(line, 1, RSTART - 1)
        rest = substr(line, RSTART + RLENGTH)
        esc = 0
        for (i = 1; i <= length(rest); i++) {
          c = substr(rest, i, 1)
          if (esc) { esc = 0; continue }
          if (c == "\\") { esc = 1; continue }
          if (c == "\"") {
            rest = substr(rest, i + 1)
            return pre "\"activated_prefix\": \"" prefix "\"" rest
          }
        }
      }
      return line
    }
    BEGIN { prefix = ENVIRON["ESCAPED"] }
    {
      if ($0 ~ /"activated_prefix"/) print replace_prefix($0, prefix)
      else print
    }
  ' "$file" | sysroot_write_file "$file"
}

sysroot_rewrite_prefix() {
  local old=$1 new=$2 root=$3 pc
  [ -d "$root" ] || return 0
  while IFS= read -r -d '' pc; do
    OLD="$old" NEW="$new" awk '
      BEGIN { old = ENVIRON["OLD"]; newp = ENVIRON["NEW"] }
      $0 == "prefix=" old { print "prefix=" newp; next }
      { print }
    ' "$pc" | sysroot_write_file "$pc"
  done < <(find "$root" -name '*.pc' -type f -print0)
}

sysroot_pc_contains() {
  local dir=$1 text=$2
  [ -d "$dir" ] || return 1
  find "$dir" -name '*.pc' -type f -print0 | xargs -0 grep -F -q -- "$text"
}

# Two-column name map: "from to". Comments start with #.
sysroot_map() {
  local file=$1 key=$2 from to
  if [ ! -f "$file" ]; then
    echo "Missing name map: $file" >&2
    return 1
  fi
  while read -r from to _; do
    if [ -z "$from" ] || [ "${from#\#}" != "$from" ]; then
      continue
    fi
    if [ "$from" = "$key" ] && [ -n "$to" ]; then
      printf '%s\n' "$to"
      return 0
    fi
  done < "$file"
  echo "Unknown name: $key" >&2
  return 1
}
