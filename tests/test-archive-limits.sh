#!/usr/bin/env bash
# Spec for download and extract caps in pixie-pkg.
#
# These tests fail while install, pull, fetch, and latest will store or
# unpack an archive with no size, file-count, or free-space limit. They
# pass once those commands refuse the payload and leave no partial tree.
#
# Caps, chosen above the largest .pixie published by pixiewood-pkgs
# (gtk-arm-v31-4.24.1.pixie: 15.9 MiB compressed, 79.9 MiB unpacked,
# 866 members) and still small enough to stop a bomb:
#   - one download body retained: at most 48 MiB
#   - one archive unpacked: at most 160 MiB of file bytes
#   - one archive unpacked: at most 4000 regular files
#   - free space on the cache volume must not fall below 1 MiB
#   - on any of those stops, the cache object, its .partial file, and the
#     unpacked tree are removed before the command exits
#
# The same caps apply to http(s), file://, and absolute paths, and to
# user and system installs (including a system cache under /var/cache).
#
# pixie-pkg prove is not invoked. It unpacks archives only by executing
# pixie-pkg fetch, which is tested here. prove also curls the pin list
# itself in download_pin_list; that direct curl is not covered.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIXIE="$ROOT/scripts/pixie-pkg"

MAX_DOWNLOAD=$((48 * 1024 * 1024))
MAX_EXTRACT=$((160 * 1024 * 1024))
MAX_FILES=4000
RESERVE=$((1 * 1024 * 1024))
HUGE=$((52 * 1024 * 1024))
BOMB=$((168 * 1024 * 1024))
DISK_PAYLOAD=$((24 * 1024 * 1024))
MANY=4500
LEFTOVER_FILES=40
BIG=$((1 * 1024 * 1024))

failures=0

say() {
  printf '%s\n' "$*" >&2
}

fail() {
  say "FAIL $*"
  failures=$((failures + 1))
}

pass() {
  say "ok $*"
}

# --- fixtures and server -------------------------------------------------

fixtures=""
server_pid=""
port=""

cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [ -n "$fixtures" ]; then
    rm -rf "$fixtures"
  fi
}
trap cleanup EXIT

xz_of_zeros() {
  local bytes=$1 dest=$2 dir blob
  dir="$(mktemp -d)"
  blob="$dir/payload.bin"
  # Real zero blocks, not a sparse hole, so unpack writes every byte.
  dd if=/dev/zero of="$blob" bs=1M count=$((bytes / 1024 / 1024)) status=none
  tar -C "$dir" -cJf "$dest" payload.bin
  rm -rf "$dir"
}

start_server() {
  local root=$1
  local py pidfile
  pidfile="$(mktemp)"
  py="$(mktemp --suffix=.py)"
  cat > "$py" << 'PY'
import os
import socketserver
import sys

ROOT = sys.argv[1]
PORTFILE = sys.argv[2]

class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            data = b""
            while b"\r\n\r\n" not in data:
                chunk = self.request.recv(4096)
                if not chunk:
                    return
                data += chunk
                if len(data) > 65536:
                    return
            line = data.split(b"\r\n", 1)[0].decode("ascii", "replace")
            parts = line.split(" ")
            if len(parts) < 2 or parts[0] != "GET":
                self._send(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                return
            path = parts[1].split("?", 1)[0]
            self.route(path)
        except Exception:
            return

    def route(self, path):
        files = {
            "/small.pixie": "small.pixie",
            "/bomb.pixie": "bomb.pixie",
            "/many.pixie": "many.pixie",
            "/disk.pixie": "disk.pixie",
            "/huge.pixie": "huge.pixie",
            "/small.pins": "small.pins",
            "/bomb.pins": "bomb.pins",
        }
        if path in ("/nocl.pixie", "/pins-huge"):
            self.stream_close(int(os.environ["HUGE_BYTES"]))
            return
        if path == "/chunked.pixie":
            self.stream_chunked(int(os.environ["HUGE_BYTES"]))
            return
        name = files.get(path)
        if name is None:
            self._send(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        self.send_file(os.path.join(ROOT, name))

    def _send(self, blob):
        self.request.sendall(blob)

    def send_file(self, path):
        size = os.path.getsize(path)
        head = (
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: application/octet-stream\r\n"
            "Content-Length: %d\r\n"
            "Connection: close\r\n\r\n" % size
        ).encode()
        self._send(head)
        with open(path, "rb") as handle:
            while True:
                buf = handle.read(1024 * 1024)
                if not buf:
                    break
                self.request.sendall(buf)

    def stream_close(self, total):
        head = (
            "HTTP/1.0 200 OK\r\n"
            "Content-Type: application/octet-stream\r\n"
            "Connection: close\r\n\r\n"
        ).encode()
        self._send(head)
        self._body(total)

    def stream_chunked(self, total):
        head = (
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: application/octet-stream\r\n"
            "Transfer-Encoding: chunked\r\n"
            "Connection: close\r\n\r\n"
        ).encode()
        self._send(head)
        block = b"\0" * (1024 * 1024)
        left = total
        while left:
            take = block if left >= len(block) else block[:left]
            self.request.sendall(("%x\r\n" % len(take)).encode())
            self.request.sendall(take)
            self.request.sendall(b"\r\n")
            left -= len(take)
        self.request.sendall(b"0\r\n\r\n")

    def _body(self, total):
        block = b"\0" * (1024 * 1024)
        left = total
        while left:
            take = block if left >= len(block) else block[:left]
            self.request.sendall(take)
            left -= len(take)

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

server = Server(("127.0.0.1", 0), Handler)
with open(PORTFILE, "w", encoding="ascii") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY
  HUGE_BYTES=$HUGE python3 "$py" "$root" "$pidfile" &
  server_pid=$!
  local i
  for i in $(seq 1 100); do
    if [ -s "$pidfile" ]; then
      port="$(tr -d '[:space:]' < "$pidfile")"
      break
    fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
      say "fixture server exited"
      exit 1
    fi
    sleep 0.05
  done
  if [ -z "$port" ]; then
    say "fixture server did not bind"
    exit 1
  fi
  rm -f "$py" "$pidfile"
}

write_pins() {
  local dest=$1 url=$2
  jq -n --arg url "$url" '{
    packages: [
      {
        abi: "arm64-v8a",
        repo: "https://example.invalid/attacker.git",
        name: "gtk",
        track: "1",
        resolved: "a",
        inputs: "b",
        url: $url
      }
    ]
  }' > "$dest"
}

prepare_fixtures() {
  local mode=$1
  fixtures="$(mktemp -d)"
  local tree small
  tree="$(mktemp -d)"
  mkdir -p "$tree/lib/arm64-v8a/pkgconfig"
  cat > "$tree/lib/arm64-v8a/pkgconfig/gtk4.pc" << 'EOF'
prefix=/
libdir=${prefix}/lib/arm64-v8a
Name: gtk4
Version: 1
Libs: -L${libdir} -lgtk4
EOF
  printf '%s\n' gtk4 > "$tree/lib/arm64-v8a/libgtk4.so"
  tar -C "$tree" -cJf "$fixtures/small.pixie" .
  rm -rf "$tree"

  if [ "$mode" = full ]; then
    xz_of_zeros "$BOMB" "$fixtures/bomb.pixie"
    xz_of_zeros "$DISK_PAYLOAD" "$fixtures/disk.pixie"
    dd if=/dev/zero of="$fixtures/huge.pixie" bs=1M count=$((HUGE / 1024 / 1024)) status=none
    local many dir i
    many="$(mktemp -d)"
    python3 - "$many" "$MANY" << 'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
count = int(sys.argv[2])
root.mkdir(parents=True, exist_ok=True)
for i in range(count):
    (root / ("f%d" % i)).write_text("x")
PY
    tar -C "$many" -cJf "$fixtures/many.pixie" .
    rm -rf "$many"
  else
    xz_of_zeros "$DISK_PAYLOAD" "$fixtures/disk.pixie"
  fi

  start_server "$fixtures"
  write_pins "$fixtures/small.pins" "http://127.0.0.1:${port}/small.pixie"
  if [ "$mode" = full ]; then
    write_pins "$fixtures/bomb.pins" "http://127.0.0.1:${port}/bomb.pixie"
  fi
  say "fixtures on 127.0.0.1:${port}"
}

# --- assertions ----------------------------------------------------------

new_case() {
  case_dir="$(mktemp -d)"
  case_home="$case_dir/home"
  case_tmp="$case_dir/tmp"
  case_prefix="$case_dir/prefix"
  case_dest="$case_dir/dest"
  mkdir -p "$case_home" "$case_tmp" "$case_prefix" "$case_dest"
}

run_pkg() {
  local stdout=$1 stderr=$2
  shift 2
  set +e
  env HOME="$case_home" TMPDIR="$case_tmp" "$@" >"$stdout" 2>"$stderr"
  status=$?
  set -e
}

largest_in() {
  local root bytes
  largest=0
  for root in "$@"; do
    [ -d "$root" ] || continue
    while IFS= read -r bytes; do
      [ -n "$bytes" ] || continue
      if [ "$bytes" -gt "$largest" ]; then
        largest=$bytes
      fi
    done < <(find "$root" -type f -printf '%s\n' 2>/dev/null || true)
  done
}

count_in() {
  local root
  counted=0
  for root in "$@"; do
    [ -d "$root" ] || continue
    counted=$((counted + $(find "$root" -type f 2>/dev/null | wc -l)))
  done
}

# A refused install must not keep the body or the unpacked tree.
# Caller has already called new_case, and every path the command writes
# is under case_home, case_tmp, case_prefix, or case_dest.
assert_rejected() {
  local name=$1
  shift
  local stdout="$case_dir/stdout" stderr="$case_dir/stderr"
  run_pkg "$stdout" "$stderr" "$@"
  local bad=0
  if [ "$status" -eq 0 ]; then
    say "$name: command exited 0"
    bad=1
  fi
  largest_in "$case_home" "$case_tmp" "$case_prefix" "$case_dest"
  if [ "$largest" -gt "$BIG" ]; then
    say "$name: left a file of $largest bytes (cap for a retained body is $MAX_DOWNLOAD, extract cap is $MAX_EXTRACT)"
    find "$case_home" "$case_tmp" "$case_prefix" "$case_dest" -type f -printf '%s %p\n' 2>/dev/null | awk -v big="$BIG" '$1 > big' >&2 || true
    bad=1
  fi
  count_in "$case_home" "$case_tmp" "$case_prefix" "$case_dest"
  if [ "$counted" -gt "$LEFTOVER_FILES" ]; then
    say "$name: left $counted files; partial tree was not removed (file cap is $MAX_FILES)"
    bad=1
  fi
  if [ "$bad" -ne 0 ]; then
    say "--- stderr ($name) ---"
    cat "$stderr" >&2 || true
    fail "$name"
  else
    pass "$name"
  fi
  rm -rf "$case_dir"
}

assert_accepted() {
  local name=$1
  shift
  local stdout="$case_dir/stdout" stderr="$case_dir/stderr"
  run_pkg "$stdout" "$stderr" "$@"
  if [ "$status" -ne 0 ]; then
    say "$name: command exited $status"
    cat "$stderr" >&2 || true
    fail "$name"
  else
    pass "$name"
  fi
  rm -rf "$case_dir"
}

avail_of() {
  df -B1 --output=avail "$1" | awk 'NR==2 { print $1 }'
}

# Free space is sampled while the command runs, and again after it exits,
# before any of its files are removed. Filling the volume and deleting the
# tree afterwards still fails.
assert_disk() {
  local name=$1 mountpoint=$2
  shift 2
  new_case
  # Keep the unpack on the volume under test. mktemp follows TMPDIR.
  case_tmp="$mountpoint/work"
  mkdir -p "$case_tmp"
  local stdout="$case_dir/stdout" stderr="$case_dir/stderr"
  set +e
  env HOME="$case_home" TMPDIR="$case_tmp" "$@" >"$stdout" 2>"$stderr" &
  local pid=$!
  local min now
  min="$(avail_of "$mountpoint")"
  while kill -0 "$pid" 2>/dev/null; do
    now="$(avail_of "$mountpoint")"
    if [ -n "$now" ] && [ "$now" -lt "$min" ]; then
      min=$now
    fi
    sleep 0.01
  done
  wait "$pid"
  status=$?
  set -e
  now="$(avail_of "$mountpoint")"
  if [ -n "$now" ] && [ "$now" -lt "$min" ]; then
    min=$now
  fi
  local bad=0
  if [ "$status" -eq 0 ]; then
    say "$name: command exited 0 on a volume smaller than the archive"
    bad=1
  fi
  if [ -z "$min" ] || [ "$min" -lt "$RESERVE" ]; then
    say "$name: free space fell to ${min:-unknown} bytes (reserve is $RESERVE)"
    bad=1
  fi
  largest_in "$mountpoint" "$case_home" "$case_tmp"
  if [ "$largest" -gt "$BIG" ]; then
    say "$name: left a file of $largest bytes on the volume"
    bad=1
  fi
  if [ "$bad" -ne 0 ]; then
    say "--- stderr ($name) ---"
    cat "$stderr" >&2 || true
    fail "$name"
  else
    pass "$name"
  fi
  rm -rf "$case_dir"
  rm -rf "$case_tmp"
}

# --- cases ---------------------------------------------------------------

run_full() {
  prepare_fixtures full

  new_case
  assert_accepted "small http install still works" \
    "$PIXIE" install --prefix "$case_prefix" --pins "$fixtures/small.pins"

  local bomb_pins="$fixtures/bomb.pins"
  new_case
  assert_rejected "install refuses an xz archive that unpacks past ${MAX_EXTRACT} bytes" \
    "$PIXIE" install --prefix "$case_prefix" --pins "$bomb_pins"
  new_case
  assert_rejected "pull refuses an xz archive that unpacks past ${MAX_EXTRACT} bytes" \
    "$PIXIE" pull --force --prefix "$case_prefix" --pins "$bomb_pins"
  new_case
  assert_rejected "fetch refuses an xz archive that unpacks past ${MAX_EXTRACT} bytes" \
    "$PIXIE" fetch --dest "$case_dest" --pins "$bomb_pins"
  new_case
  assert_rejected "latest refuses an xz archive that unpacks past ${MAX_EXTRACT} bytes" \
    "$PIXIE" latest --dest "$case_dest" --pins "$bomb_pins"
  new_case
  assert_rejected "user install refuses an xz archive that unpacks past ${MAX_EXTRACT} bytes" \
    "$PIXIE" install --user --pins "$bomb_pins"

  local huge_pins="$fixtures/huge.pins"
  write_pins "$huge_pins" "http://127.0.0.1:${port}/huge.pixie"
  new_case
  assert_rejected "install refuses a download larger than ${MAX_DOWNLOAD} bytes" \
    "$PIXIE" install --prefix "$case_prefix" --pins "$huge_pins"

  local file_pins="$fixtures/file.pins"
  write_pins "$file_pins" "file://${fixtures}/huge.pixie"
  new_case
  assert_rejected "install refuses a file:// download larger than ${MAX_DOWNLOAD} bytes" \
    "$PIXIE" install --prefix "$case_prefix" --pins "$file_pins"

  local path_pins="$fixtures/path.pins"
  write_pins "$path_pins" "${fixtures}/huge.pixie"
  new_case
  assert_rejected "install refuses an absolute-path copy larger than ${MAX_DOWNLOAD} bytes" \
    "$PIXIE" install --prefix "$case_prefix" --pins "$path_pins"

  local many_pins="$fixtures/many.pins"
  write_pins "$many_pins" "http://127.0.0.1:${port}/many.pixie"
  new_case
  assert_rejected "install refuses an archive with more than ${MAX_FILES} files" \
    "$PIXIE" install --prefix "$case_prefix" --pins "$many_pins"

  local nocl_pins="$fixtures/nocl.pins"
  write_pins "$nocl_pins" "http://127.0.0.1:${port}/nocl.pixie"
  new_case
  assert_rejected "install caps a body that has no Content-Length" \
    "$PIXIE" install --prefix "$case_prefix" --pins "$nocl_pins"

  local chunk_pins="$fixtures/chunk.pins"
  write_pins "$chunk_pins" "http://127.0.0.1:${port}/chunked.pixie"
  new_case
  assert_rejected "install caps a chunked body that has no Content-Length" \
    "$PIXIE" install --prefix "$case_prefix" --pins "$chunk_pins"

  new_case
  assert_rejected "install caps a pin list larger than ${MAX_DOWNLOAD} bytes" \
    "$PIXIE" install --prefix "$case_prefix" --pins "http://127.0.0.1:${port}/pins-huge"

  # Remote pin list whose package URL is the bomb. Same bytes as --pins file.
  new_case
  assert_rejected "install follows a downloaded pin list to an oversized archive" \
    "$PIXIE" install --prefix "$case_prefix" --pins "http://127.0.0.1:${port}/bomb.pins"
}

run_disk() {
  if [ "$(id -u)" -ne 0 ]; then
    say "disk cases need a mount namespace"
    exit 1
  fi
  prepare_fixtures disk
  local disk_pins="$fixtures/disk.pins"
  write_pins "$disk_pins" "http://127.0.0.1:${port}/disk.pixie"

  local vol
  vol="$(mktemp -d)"
  mount -t tmpfs -o size=16M tmpfs "$vol"
  assert_disk "prefix install stops before a short cache volume fills" \
    "$vol" \
    "$PIXIE" install --prefix "$vol/prefix" --pins "$disk_pins"
  umount "$vol" || true
  rmdir "$vol" || true

  local varcache
  varcache="$(mktemp -d)"
  mount -t tmpfs -o size=16M tmpfs "$varcache"
  mount --bind "$varcache" /var/cache
  assert_disk "system install stops before /var/cache fills" \
    /var/cache \
    "$PIXIE" install --system --pins "$disk_pins"
  umount /var/cache || true
  umount "$varcache" || true
  rmdir "$varcache" || true
}

set -e
if [ "${1:-}" = "--disk-only" ]; then
  run_disk
  if [ "$failures" -ne 0 ]; then
    say "$failures disk assertion(s) failed"
    exit 1
  fi
  say "disk assertions passed"
  exit 0
fi

run_full
if unshare --user --map-root-user --mount true; then
  set +e
  unshare --user --map-root-user --mount bash "$0" --disk-only
  disk_status=$?
  set -e
  if [ "$disk_status" -ne 0 ]; then
    fail "disk-space cases (exit $disk_status)"
  fi
else
  fail "could not start a mount namespace for the disk-space cases"
fi

if [ "$failures" -ne 0 ]; then
  say "$failures assertion(s) failed"
  exit 1
fi
say "all archive limit assertions passed"
exit 0
