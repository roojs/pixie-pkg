#!/usr/bin/env bash
# A pin list must not leave another local account able to read a file that
# was restricted to root.
#
# install, pull, and fetch all pass package URLs through download_rows and
# fetch_to. prove does too: it calls fetch. These checks fail while a
# file URL is copied into the cache with the process umask and kept after
# the archive extract fails. They pass when that copy is not readable by
# other accounts, including when the URL is rejected or the copy is removed.
# An absolute path in the same field is the other fetch_to branch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIXIE="$ROOT/scripts/pixie-pkg"

if ! sudo -n true >/dev/null 2>&1; then
  echo "sudo is required to run the system install as root" >&2
  exit 1
fi
command -v jq >/dev/null
command -v python3 >/dev/null

MARKER='LOCAL-FILE-MARKER-pixie-disclosure'
base="$(mktemp -d)"
chmod 0755 "$base"
secret="/root/pixie-disclosure-marker"
http_pid=""
failures=0

cleanup() {
  if [ -n "$http_pid" ]; then
    kill "$http_pid" >/dev/null 2>&1 || true
  fi
  sudo rm -rf -- "$secret" "$base"
}
trap cleanup EXIT

printf '%s\n' "$MARKER" | sudo tee "$secret" >/dev/null
sudo chmod 0600 "$secret"
sudo chown root:root "$secret"

pins_with() {
  local url=$1 dest=$2
  jq -n --arg url "$url" '{
    packages: [{
      abi: "arm64-v8a",
      repo: "https://example.invalid/pkg.git",
      name: "gtk",
      track: "1",
      resolved: "abc",
      inputs: "def",
      url: $url
    }]
  }' > "$dest"
}

# Print cache files another account can read, and return 1 when the marker
# is among them. Return 0 when this tree does not disclose the marker.
other_account_reads_marker() {
  local tree=$1 label=$2 found=0 file mode
  [ -d "$tree" ] || return 0
  while IFS= read -r -d '' file; do
    mode="$(sudo stat -c '%a' "$file")"
    if sudo -u nobody cat -- "$file" 2>/dev/null | grep -q -F "$MARKER"; then
      echo "$label: nobody read $file (mode $mode)" >&2
      found=1
    fi
  done < <(sudo find "$tree" -type f -print0)
  [ "$found" -eq 0 ]
}

run_case() {
  local name=$1
  shift
  local prefix="$base/$name"
  local log="$base/$name.log"
  sudo rm -rf -- "$prefix"
  mkdir -m 0755 "$prefix"
  set +e
  sudo -- "$PIXIE" "$@" >"$log.out" 2>"$log.err"
  local status=$?
  set -e
  echo "$name: pixie-pkg exit $status" >&2
  if ! other_account_reads_marker "$prefix" "$name"; then
    echo "$name: cache still discloses the root-only file" >&2
    sed -n '1,40p' "$log.err" >&2
    failures=$((failures + 1))
  fi
}

# Local pin list, file URL. install, pull, and fetch share download_rows.
pins_with "file://${secret}" "$base/file.pins"
run_case install-file \
  install --prefix "$base/install-file" --pins "$base/file.pins"
run_case pull-file \
  pull --force --prefix "$base/pull-file" --pins "$base/file.pins"
mkdir -m 0755 "$base/fetch-dest"
run_case fetch-file \
  fetch --dest "$base/fetch-dest" --prefix "$base/fetch-file" --pins "$base/file.pins"
# fetch --dest writes outside the prefix; check that tree as well.
if ! other_account_reads_marker "$base/fetch-dest" fetch-dest; then
  echo "fetch-dest: unpacked tree discloses the root-only file" >&2
  failures=$((failures + 1))
fi

# Pin list fetched over HTTP, package URL still a file URL.
pins_with "file://${secret}" "$base/pins.json"
port=8765
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$base" >"$base/http.log" 2>&1 &
http_pid=$!
for _ in 1 2 3 4 5 10; do
  if curl -fsS "http://127.0.0.1:${port}/pins.json" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
run_case install-http-pins \
  install --prefix "$base/install-http-pins" --pins "http://127.0.0.1:${port}/pins.json"
kill "$http_pid" >/dev/null 2>&1 || true
http_pid=""

# Absolute path in the url field. cp keeps the source mode on coreutils 9.4,
# so this must stay unreadable to other accounts as well.
pins_with "$secret" "$base/abs.pins"
run_case install-absolute \
  install --prefix "$base/install-absolute" --pins "$base/abs.pins"
run_case pull-absolute \
  pull --force --prefix "$base/pull-absolute" --pins "$base/abs.pins"
mkdir -m 0755 "$base/fetch-abs-dest"
run_case fetch-absolute \
  fetch --dest "$base/fetch-abs-dest" --prefix "$base/fetch-absolute" --pins "$base/abs.pins"
if ! other_account_reads_marker "$base/fetch-abs-dest" fetch-abs-dest; then
  echo "fetch-abs-dest: unpacked tree discloses the root-only file" >&2
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  echo "local file disclosure: $failures case(s) failed" >&2
  exit 1
fi
echo "local file disclosure: ok"
