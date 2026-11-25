#!/usr/bin/env bash
# Archived setuid, setgid, and device-node metadata must not survive unpack.
#
# pixie-pkg install, pull, fetch, and latest extract a caller-supplied
# .pixie archive with tar. These tests fail while that extract applies the
# mode and special-file metadata stored in the archive. They pass when the
# extract ignores those bits, or rejects the member, without ever creating
# the privileged file or device node.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIXIE="$ROOT/scripts/pixie-pkg"

build_inputs() {
  local work=$1
  local probe="$work/probe" archive="$work/evil.pixie" pins="$work/pins.json"
  cat > "$work/probe.c" << 'EOF'
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
  FILE *f;
  if (argc != 2) return 2;
  f = fopen(argv[1], "w");
  if (!f) return 2;
  fprintf(f, "%ld %ld\n", (long)geteuid(), (long)getegid());
  fclose(f);
  return 0;
}
EOF
  gcc -O2 -o "$probe" "$work/probe.c"
  python3 - "$probe" "$archive" << 'PY'
import io, sys, tarfile
probe = open(sys.argv[1], "rb").read()
pc = b"prefix=/\nlibdir=${prefix}/lib/arm64-v8a\nName: gtk4\nVersion: 1\nLibs: -lgtk-4\n"
dest = sys.argv[2]

def add(tar, name, mode, typ, data=b"", major=0, minor=0):
    info = tarfile.TarInfo(name)
    info.type = typ
    info.mode = mode
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    if typ in (tarfile.CHRTYPE, tarfile.BLKTYPE):
        info.devmajor = major
        info.devminor = minor
        info.size = 0
        tar.addfile(info)
        return
    if typ == tarfile.DIRTYPE:
        info.size = 0
        tar.addfile(info)
        return
    info.size = len(data)
    tar.addfile(info, io.BytesIO(data))

with tarfile.open(dest, "w:xz") as tar:
    add(tar, "lib/arm64-v8a/pkgconfig/gtk4.pc", 0o644, tarfile.REGTYPE, pc)
    add(tar, "planted/idprobe", 0o4755, tarfile.REGTYPE, probe)
    add(tar, "planted/sgid-probe", 0o2755, tarfile.REGTYPE, probe)
    add(tar, "sgiddir", 0o2755, tarfile.DIRTYPE)
    add(tar, "planted/nulldev", 0o666, tarfile.CHRTYPE, major=1, minor=3)
    add(tar, "planted/ramdisk", 0o660, tarfile.BLKTYPE, major=1, minor=0)
PY
  listing="$(tar -tvJf "$archive")"
  printf '%s\n' "$listing" | grep -q 'rwsr-xr-x root/root .*planted/idprobe'
  printf '%s\n' "$listing" | grep -q 'rwxr-sr-x root/root .*planted/sgid-probe'
  printf '%s\n' "$listing" | grep -q 'drwxr-sr-x root/root .*sgiddir'
  printf '%s\n' "$listing" | grep -q 'crw-rw-rw- root/root .*planted/nulldev'
  printf '%s\n' "$listing" | grep -q 'brw-rw---- root/root .*planted/ramdisk'
  printf '%s\n' "$(id -u)" > "$work/builder.uid"
  jq -n --arg url "file://${archive}" '{
    packages: [{
      abi: "arm64-v8a",
      repo: "https://gitlab.gnome.org/GNOME/gtk.git",
      name: "gtk",
      track: "4",
      resolved: "abc",
      inputs: "def",
      url: $url
    }]
  }' > "$pins"
  cat > "$work/priv.c" << 'EOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static void note(const char *op, const char *path, mode_t mode) {
  const char *log = getenv("PIXIE_PRIV_LOG");
  FILE *f;
  if (!log || !log[0]) return;
  if ((mode & (S_ISUID | S_ISGID)) == 0 && !S_ISCHR(mode) && !S_ISBLK(mode))
    return;
  f = fopen(log, "a");
  if (!f) return;
  fprintf(f, "%s %s %o\n", op, path ? path : "-", (unsigned)mode);
  fclose(f);
}

int chmod(const char *path, mode_t mode) {
  static int (*real)(const char *, mode_t) = 0;
  int rc;
  if (!real) real = dlsym(RTLD_NEXT, "chmod");
  rc = real(path, mode);
  if (rc == 0) note("chmod", path, mode);
  return rc;
}

int fchmod(int fd, mode_t mode) {
  static int (*real)(int, mode_t) = 0;
  int rc;
  if (!real) real = dlsym(RTLD_NEXT, "fchmod");
  rc = real(fd, mode);
  if (rc == 0) note("fchmod", 0, mode);
  return rc;
}

int fchmodat(int dirfd, const char *path, mode_t mode, int flags) {
  static int (*real)(int, const char *, mode_t, int) = 0;
  int rc;
  if (!real) real = dlsym(RTLD_NEXT, "fchmodat");
  rc = real(dirfd, path, mode, flags);
  if (rc == 0) note("fchmodat", path, mode);
  return rc;
}

int mknodat(int dirfd, const char *path, mode_t mode, dev_t dev) {
  static int (*real)(int, const char *, mode_t, dev_t) = 0;
  int rc;
  if (!real) real = dlsym(RTLD_NEXT, "mknodat");
  rc = real(dirfd, path, mode, dev);
  if (rc == 0) note("mknodat", path, mode);
  return rc;
}

int mknod(const char *path, mode_t mode, dev_t dev) {
  static int (*real)(const char *, mode_t, dev_t) = 0;
  int rc;
  if (!real) real = dlsym(RTLD_NEXT, "mknod");
  rc = real(path, mode, dev);
  if (rc == 0) note("mknod", path, mode);
  return rc;
}
EOF
  gcc -shared -fPIC -O2 -o "$work/priv.so" "$work/priv.c"
  chmod a+rX "$work" "$archive" "$pins" "$work/priv.so" "$probe"
}

if [ "$(id -u)" -ne 0 ]; then
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  build_inputs "$work"
  exec sudo -n -- "$0" "$work"
fi

work=${1:-}
if [ -z "$work" ] || [ ! -d "$work" ]; then
  echo "usage: $0 WORKDIR" >&2
  exit 2
fi

host_lib_existed=0
host_cache_existed=0
[ -e /usr/lib/pixie ] && host_lib_existed=1
[ -e /var/cache/pixie ] && host_cache_existed=1

cleanup() {
  rm -rf "$work"
  if [ "$host_lib_existed" -eq 0 ]; then
    if [ -d /usr/lib/pixie ]; then
      find /usr/lib/pixie -mindepth 1 -delete 2>/dev/null || true
      rmdir /usr/lib/pixie 2>/dev/null || true
    fi
  fi
  if [ "$host_cache_existed" -eq 0 ]; then
    if [ -d /var/cache/pixie ]; then
      find /var/cache/pixie -mindepth 1 -delete 2>/dev/null || true
      rmdir /var/cache/pixie 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT


if [ ! -x "$work/probe" ] || [ ! -f "$work/evil.pixie" ]; then
  build_inputs "$work"
fi

log="$work/priv.log"
so="$work/priv.so"
pins="$work/pins.json"
tmp="$work/tmp"
mkdir -p "$tmp" "$work/home"
touch "$log"
failures=0

note_fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

privileged_entries() {
  local root=$1
  [ -d "$root" ] || return 0
  find "$root" \( -perm /6000 -o -type b -o -type c \) -printf '%m %u %g %y %p\n'
}

assert_tree_clean() {
  local label=$1 root=$2 entries
  entries="$(privileged_entries "$root")"
  if [ -n "$entries" ]; then
    note_fail "$label left privileged files or device nodes"
    printf '%s\n' "$entries" >&2
  fi
}

assert_log_clean() {
  local label=$1
  if [ -s "$log" ]; then
    note_fail "$label applied privileged metadata during extract"
    cat "$log" >&2
  fi
}

run_pkg() {
  : > "$log"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  set +e
  env LD_PRELOAD="$so" PIXIE_PRIV_LOG="$log" TMPDIR="$tmp" HOME="$work/home" \
    "$PIXIE" "$@" >/dev/null
  local rc=$?
  set -e
  printf '%s\n' "$rc"
}

check_execution() {
  local label=$1 tree=$2 name=$3 probe out
  probe="$(find "$tree" -type f -name "$name" 2>/dev/null | head -n 1 || true)"
  [ -n "$probe" ] || return 0
  [ -x "$probe" ] || return 0
  find "$tree" -type d -exec chmod a+rx {} +
  chmod a+rx "$work"
  out="$work/euid.txt"
  rm -f "$out"
  touch "$out"
  chmod 666 "$out"
  set +e
  runuser -u nobody -- "$probe" "$out"
  set -e
  if [ -s "$out" ] && grep -Eq '(^|[[:space:]])0([[:space:]]|$)' "$out"; then
    note_fail "$label $name ran with root credentials: $(cat "$out")"
  fi
}

check_command() {
  local label=$1
  shift
  local rc dest arg prev=""
  local -a trees=()
  rc="$(run_pkg "$@")"
  assert_log_clean "$label"
  assert_tree_clean "$label" "$tmp"
  for arg in "$@"; do
    if [ "$prev" = "--prefix" ] || [ "$prev" = "--dest" ]; then
      trees+=("$arg")
    fi
    prev=$arg
  done
  for dest in "${trees[@]}"; do
    assert_tree_clean "$label" "$dest"
    check_execution "$label" "$dest" idprobe
    check_execution "$label" "$dest" sgid-probe
  done
  printf '%s rc=%s\n' "$label" "$rc" >&2
}

prefix="$work/prefix-install"
check_command install install --prefix "$prefix" --pins "$pins" --abi arm64-v8a

prefix="$work/prefix-pull"
check_command pull pull --force --prefix "$prefix" --pins "$pins" --abi arm64-v8a

fetch="$work/fetch"
mkdir -p "$fetch"
check_command fetch fetch --dest "$fetch" --prefix "$work/prefix-fetch-cache" \
  --pins "$pins" --abi arm64-v8a

latest="$work/latest"
mkdir -p "$latest"
check_command latest latest --dest "$latest" --prefix "$work/prefix-latest-cache" \
  --pins "$pins" --abi arm64-v8a

# Root with no --prefix uses /usr/lib/pixie. Keep that directory on a private
# bind mount so the default system path is exercised without publishing the
# archive onto the host's real library directory.
ns_lib="$work/ns-lib"
ns_cache="$work/ns-cache"
mkdir -p "$ns_lib" "$ns_cache"
: > "$log"
rm -rf "$tmp"
mkdir -p "$tmp"
set +e
unshare --mount --propagation private bash -c "
  set -euo pipefail
  mkdir -p /usr/lib/pixie /var/cache/pixie
  mount --bind '$ns_lib' /usr/lib/pixie
  mount --bind '$ns_cache' /var/cache/pixie
  export LD_PRELOAD='$so'
  export PIXIE_PRIV_LOG='$log'
  export TMPDIR='$tmp'
  export HOME='$work/home'
  '$PIXIE' install --pins '$pins' --abi arm64-v8a >/dev/null
"
ns_rc=$?
set -e
printf 'default-root-install rc=%s\n' "$ns_rc" >&2
assert_log_clean "default root install"
assert_tree_clean "default root install" "$ns_lib"
assert_tree_clean "default root install" "$ns_cache"
assert_tree_clean "default root install" "$tmp"
check_execution "default root install" "$ns_lib" idprobe
check_execution "default root install" "$ns_lib" sgid-probe
if [ -e /usr/lib/pixie/release ] || [ -e /var/cache/pixie/release ]; then
  note_fail "default root install wrote through onto the host library path"
fi

# A user install is the same unpack. It must not leave privileged metadata
# either, including when tar refuses a device node and the command fails.
user_home="$work/user-home"
mkdir -p "$user_home" "$tmp"
chown nobody:nogroup "$user_home" "$tmp"
chmod 1777 "$tmp"
chmod a+rx "$work"
chmod a+r "$pins" "$work/evil.pixie" "$so"
: > "$log"
chmod 666 "$log"
set +e
runuser -u nobody -- env LD_PRELOAD="$so" PIXIE_PRIV_LOG="$log" \
  TMPDIR="$tmp" HOME="$user_home" \
  "$PIXIE" install --user --pins "$pins" --abi arm64-v8a >/dev/null
user_rc=$?
set -e
printf 'user-install rc=%s\n' "$user_rc" >&2
assert_log_clean "user install"
assert_tree_clean "user install" "$user_home"
assert_tree_clean "user install" "$tmp"

if [ "$failures" -ne 0 ]; then
  echo "privileged unpack metadata was preserved ($failures checks)" >&2
  exit 1
fi

echo "unpack privileges: ok"
