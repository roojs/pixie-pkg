# Shared helpers for the sysroot scripts. Source this file; do not execute it.

# Limits for one download and for one unpacked archive. The largest
# published .pixie is about 16 MiB compressed and 80 MiB unpacked with
# fewer than 900 members. PIXIE_MIN_FREE is the space a download or an
# unpack leaves free on its volume.
PIXIE_MAX_DOWNLOAD=${PIXIE_MAX_DOWNLOAD:-$((48 * 1024 * 1024))}
PIXIE_MAX_UNPACK=${PIXIE_MAX_UNPACK:-$((160 * 1024 * 1024))}
PIXIE_MAX_FILES=${PIXIE_MAX_FILES:-4000}
PIXIE_MIN_FREE=${PIXIE_MIN_FREE:-$((16 * 1024 * 1024))}
PIXIE_XZ_MEMLIMIT=${PIXIE_XZ_MEMLIMIT:-$((128 * 1024 * 1024))}

pixie_check_limits() {
  local name value
  for name in PIXIE_MAX_DOWNLOAD PIXIE_MAX_UNPACK PIXIE_MAX_FILES PIXIE_MIN_FREE PIXIE_XZ_MEMLIMIT; do
    value=${!name}
    case "$value" in
      ''|*[!0-9]*)
        echo "$name must be a whole number: $value" >&2
        return 1
        ;;
    esac
  done
}

pixie_free_bytes() {
  local kib
  kib="$(df -Pk -- "$1" | awk 'NR == 2 { print $4 }')"
  case "$kib" in
    ''|*[!0-9]*)
      echo "Cannot read the free space of $1" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$((kib * 1024))"
}

# Run a command that may not write more than BYTES to any one file.
# SIGXFSZ is ignored so the write fails with EFBIG and the command exits.
pixie_capped() {
  local bytes=$1
  shift
  (
    trap '' XFSZ
    ulimit -S -f "$((bytes / 1024))" 2>/dev/null || true
    [ "$(ulimit -S -f)" != unlimited ] || exit 1
    exec "$@"
  )
}

# Copy URL (http, https, file, or a local path) to DEST. The body may not
# be larger than PIXIE_MAX_DOWNLOAD or leave less than PIXIE_MIN_FREE on
# the volume of DEST. DEST is removed when the copy fails.
pixie_fetch_capped() {
  local url=$1 dest=$2 dir free limit status=0 size
  pixie_check_limits || return 1
  dir="$(dirname "$dest")"
  mkdir -p "$dir" || return 1
  free="$(pixie_free_bytes "$dir")" || return 1
  limit=$((free - PIXIE_MIN_FREE))
  if [ "$limit" -gt "$PIXIE_MAX_DOWNLOAD" ]; then
    limit=$PIXIE_MAX_DOWNLOAD
  fi
  limit=$((limit / 1024 * 1024))
  if [ "$limit" -le 0 ]; then
    echo "Not enough free space in $dir to download $url" >&2
    return 1
  fi
  rm -f "$dest"
  case "$url" in
    http://*|https://*)
      pixie_capped "$limit" curl -fsSL --retry 3 --retry-delay 2 --max-filesize "$limit" "$url" -o "$dest" || status=$?
      ;;
    file://*)
      pixie_capped "$limit" curl -fsSL --max-filesize "$limit" "$url" -o "$dest" || status=$?
      ;;
    *)
      pixie_capped "$limit" cat -- "$url" > "$dest" || status=$?
      ;;
  esac
  if [ "$status" -eq 0 ]; then
    return 0
  fi
  size="$(stat -c %s -- "$dest" 2>/dev/null || echo 0)"
  rm -f "$dest"
  if [ "$status" -eq 63 ] || [ "$size" -ge "$limit" ]; then
    if [ "$limit" -lt "$PIXIE_MAX_DOWNLOAD" ]; then
      echo "Not enough free space in $dir for $url" >&2
    else
      echo "Download is larger than $PIXIE_MAX_DOWNLOAD bytes: $url" >&2
    fi
  fi
  return 1
}

pixie_xz_stream() {
  xz -dc --format=xz --memlimit-decompress="$PIXIE_XZ_MEMLIMIT" < "$1"
}

# Print "need largest" for the xz tar at SRC without writing it. need is
# the space the members take in blocks of BLOCK bytes; largest is the
# largest member. Parent directories that tar would create count as files.
pixie_archive_plan() {
  local src=$1 block=$2 stream_limit=$3
  pixie_xz_stream "$src" \
    | head -c "$stream_limit" \
    | tar -tvf - --numeric-owner --quoting-style=c \
    | awk -v block="$block" -v max_files="$PIXIE_MAX_FILES" -v max_bytes="$PIXIE_MAX_UNPACK" '
      {
        type = substr($1, 1, 1)
        size = ($3 ~ /^[0-9]+$/) ? $3 + 0 : 0
        if (!match($0, /"([^"\\]|\\.)*"/)) {
          print "Cannot read the archive listing" > "/dev/stderr"
          bad = 1
          exit 1
        }
        n = split(substr($0, RSTART + 1, RLENGTH - 2), parts, "/")
        last = 0
        for (i = 1; i <= n; i++) {
          if (parts[i] != "" && parts[i] != ".") last = i
        }
        path = ""
        for (i = 1; i <= last; i++) {
          if (parts[i] == "" || parts[i] == ".") continue
          path = path "/" parts[i]
          if (i == last && type != "d") break
          if (!(path in dirs)) {
            dirs[path] = 1
            entries++
            need += block
          }
        }
        if (type != "d") {
          entries++
          bytes += size
          need += block + int((size + block - 1) / block) * block
          if (size > largest) largest = size
        }
        if (entries > max_files) {
          print "The archive has more than " max_files " files" > "/dev/stderr"
          bad = 1
          exit 1
        }
        if (bytes > max_bytes) {
          print "The archive unpacks to more than " max_bytes " bytes" > "/dev/stderr"
          bad = 1
          exit 1
        }
      }
      END {
        if (bad) exit 1
        printf "%.0f %.0f\n", need, largest
      }
    '
}

# Unpack the xz tar ARCHIVE into DEST. The archive is listed first and is
# refused when it has more than PIXIE_MAX_FILES files, more than
# PIXIE_MAX_UNPACK bytes, or would leave less than PIXIE_MIN_FREE on the
# volume of DEST. The listing and the unpack read the same open file.
# The caller removes DEST when this fails.
pixie_unpack() {
  local archive=$1 dest=$2 fd block stream_limit plan free status=0
  local need largest
  pixie_check_limits || return 1
  block="$(stat -f -c %S -- "$dest" 2>/dev/null || true)"
  case "$block" in
    ''|*[!0-9]*) block=4096 ;;
  esac
  if [ "$block" -lt 4096 ]; then
    block=4096
  fi
  stream_limit=$((PIXIE_MAX_UNPACK + (PIXIE_MAX_FILES + 1) * 8192))
  exec {fd}< "$archive" || return 1
  plan="$(pixie_archive_plan "/dev/fd/$fd" "$block" "$stream_limit")" || status=$?
  if [ "$status" -ne 0 ] || [ -z "$plan" ]; then
    exec {fd}<&-
    echo "Refusing archive $archive" >&2
    return 1
  fi
  read -r need largest <<< "$plan"
  free="$(pixie_free_bytes "$dest")" || { exec {fd}<&-; return 1; }
  if [ $((need + PIXIE_MIN_FREE)) -gt "$free" ]; then
    exec {fd}<&-
    echo "Not enough free space in $dest to unpack $archive ($need bytes needed, $free free)" >&2
    return 1
  fi
  pixie_xz_stream "/dev/fd/$fd" \
    | head -c "$stream_limit" \
    | pixie_capped "$((largest + 1024))" tar -C "$dest" -xf - \
    || status=$?
  exec {fd}<&-
  if [ "$status" -ne 0 ]; then
    echo "Could not unpack $archive" >&2
    return 1
  fi
}

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

sysroot_set_activated_prefix() {
  local file=$1 prefix=$2 escaped tmp
  escaped="$(sysroot_json_escape "$prefix")"
  tmp="$(mktemp)"
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
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

sysroot_rewrite_prefix() {
  local old=$1 new=$2 root=$3 pc tmp
  [ -d "$root" ] || return 0
  while IFS= read -r -d '' pc; do
    tmp="$(mktemp)"
    OLD="$old" NEW="$new" awk '
      BEGIN { old = ENVIRON["OLD"]; newp = ENVIRON["NEW"] }
      $0 == "prefix=" old { print "prefix=" newp; next }
      { print }
    ' "$pc" > "$tmp"
    mv "$tmp" "$pc"
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
