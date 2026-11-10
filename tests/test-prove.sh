#!/usr/bin/env bash
# prove chooses a published package for each library before the checkout.
# The library names live in the fixture, not in the command.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIXIE="$ROOT/scripts/pixie-pkg"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME"

make_pixie() {
  local name=$1 dest=$2 tree
  tree="$(mktemp -d)"
  mkdir -p "$tree/lib/arm64-v8a"
  printf '%s\n' "$name" > "$tree/lib/arm64-v8a/lib${name}.so"
  tar -C "$tree" -cJf "$dest" .
  rm -rf "$tree"
}

alpha_pixie="$tmp/alpha.pixie"
beta_pixie="$tmp/beta.pixie"
gamma_pixie="$tmp/gamma.pixie"
make_pixie alpha "$alpha_pixie"
make_pixie beta "$beta_pixie"
make_pixie gamma "$gamma_pixie"

pkgs="$tmp/pkgs"
mkdir -p "$pkgs/packages/alpha" "$pkgs/packages/beta" "$pkgs/packages/gamma" "$pkgs/packages/gtk" "$pkgs/scripts" "$pkgs/cross"
cat > "$pkgs/build-order.txt" << 'EOF'
alpha
beta
gamma
gtk
EOF
printf '%s\n' 'aarch64 arm64-v8a' > "$pkgs/cross/abi"
cat > "$pkgs/packages/gtk/targets" << 'EOF'
# name url revision patch
gnome https://gitlab.gnome.org/GNOME/gtk.git ae709f962a51f9108a1e6381bcfbd05bbaecc840 -
EOF
printf '%s\n' '[wrap-git]' 'revision = gnome' > "$pkgs/packages/gtk/gtk.wrap"
cat > "$pkgs/packages/alpha/alpha.wrap" << 'EOF'
[wrap-git]
revision = 9.0

[provide]
alpha = alpha_dep
EOF
cat > "$pkgs/packages/beta/beta.wrap" << 'EOF'
[wrap-git]
revision = main

[provide]
beta = beta_dep
EOF
cat > "$pkgs/packages/gamma/gamma.wrap" << 'EOF'
[wrap-git]
revision = 2.91.0

[provide]
dependency_names = gamma
EOF
repo=https://gitlab.gnome.org/GNOME/gtk.git
jq -n --arg repo "$repo" --arg alpha "file://${alpha_pixie}" --arg gamma "file://${gamma_pixie}" '{
  packages: [
    {
      abi: "arm64-v8a", repo: $repo, name: "alpha",
      track: "1.2.0", resolved: "a", inputs: "b", url: $alpha
    },
    {
      abi: "arm64-v8a", repo: $repo, name: "gamma",
      track: "2.90.1", resolved: "e", inputs: "f", url: $gamma
    }
  ]
}' > "$pkgs/release.pins"
jq -n --arg repo "$repo" --arg url "file://${beta_pixie}" '{
  packages: [{
    abi: "arm64-v8a", repo: $repo, name: "beta",
    track: "main", resolved: "c", inputs: "d", url: $url
  }]
}' > "$pkgs/snapshot.pins"
cat > "$pkgs/scripts/build-pixie.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
tarball=""
deps=""
gtk=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tarball) tarball=$2; shift 2 ;;
    --deps-sysroot) deps=$2; shift 2 ;;
    --gtk) gtk=$2; shift 2 ;;
    *) shift ;;
  esac
done
grep -q '^revision = 9.0$' packages/alpha/alpha.wrap
grep -q '^revision = main$' packages/beta/beta.wrap
grep -q '^revision = 2.91.0$' packages/gamma/gamma.wrap
test -f "$deps/lib/arm64-v8a/libalpha.so"
test -f "$deps/lib/arm64-v8a/libbeta.so"
test -f "$deps/lib/arm64-v8a/libgamma.so"
case "$gtk" in
  Knowles.*) ;;
  *) echo "unexpected target $gtk" >&2; exit 1 ;;
esac
printf '%s\n' built > "$tarball"
EOF
chmod +x "$pkgs/scripts/build-pixie.sh"

src="$tmp/gtk"
mkdir -p "$src"
cat > "$src/meson.build" << 'EOF'
project('gtk', 'c',
        version: '4.25.1',
        license: 'LGPL-2.1-or-later')

alpha_major_req = 1
alpha_minor_req = 2
alpha_req = '>= @0@.@1@'.format(alpha_major_req, alpha_minor_req)
add_project_arguments([
    '-DALPHA_VERSION_MAX_ALLOWED=G_ENCODE_VERSION(@0@,@1@)'.format(alpha_major_req, alpha_minor_req + 1),
  ], language: 'c')
alpha_dep = dependency('alpha', version: alpha_req)

gamma_major_req = 2
gamma_minor_req = 90
gamma_req = '>= 2.89.3'
add_project_arguments([
    '-DGAMMA_VERSION_MAX_ALLOWED=G_ENCODE_VERSION(@0@,@1@)'.format(gamma_major_req, gamma_minor_req),
  ], language: 'c')
gamma_dep = dependency('gamma', version: gamma_req)
EOF
git -C "$src" init -q
git -C "$src" remote add origin https://gitlab.gnome.org/Knowles/gtk.git

export PIXIE_SRC="$pkgs"
export PIXIE_SKIP_HOST_SETUP=1
out="$tmp/out"
log="$(cd "$src" && "$PIXIE" prove --tag 4.25.1-20261110c-pixie --out "$out")"
printf '%s\n' "$log"
printf '%s\n' "$log" | grep -q 'Using published alpha 1.2.0'
printf '%s\n' "$log" | grep -q 'Using published beta main'
printf '%s\n' "$log" | grep -q 'Using published gamma 2.90.1'
test -f "$out/gtk-arm-v31-4.25.1.pixie"
grep -q '^revision = 9.0$' "$pkgs/packages/alpha/alpha.wrap"
grep -q 'Knowles.4.25.1-20261110c-pixie https://gitlab.gnome.org/Knowles/gtk.git 4.25.1-20261110c-pixie -' \
  "$pkgs/packages/gtk/targets" && exit 1
# The source tree is copied. The target line is added in that copy, not here.
grep -q '^gnome ' "$pkgs/packages/gtk/targets"

# A release version outside the checkout's limit is not the package.
jq -n --arg repo "$repo" --arg url "file://${alpha_pixie}" '{
  packages: [{
    abi: "arm64-v8a", repo: $repo, name: "alpha",
    track: "9.0", resolved: "a", inputs: "b", url: $url
  }]
}' > "$pkgs/release.pins"
set +e
bad="$(cd "$src" && "$PIXIE" prove --tag 4.25.1-20261110c-pixie --out "$tmp/out2" 2>"$tmp/err")"
status=$?
set -e
[ "$status" -eq 1 ]
grep -q 'dependency would be compiled: alpha' "$tmp/err"
grep -q '^revision = 9.0$' "$pkgs/packages/alpha/alpha.wrap"
test ! -e "$tmp/out2/gtk-arm-v31-4.25.1.pixie"

set +e
(cd "$src" && "$PIXIE" prove --tag 4.25.1 --out "$out") >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 2 ]

# The command does not name the fixture libraries.
if grep -E -q 'alpha|beta|fontconfig|pango' "$ROOT/scripts/pixie-prove.sh"; then
  echo "prove names a library" >&2
  exit 1
fi

echo "prove: ok"
