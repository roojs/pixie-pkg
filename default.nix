# Build pixie. `nix-build` installs it into the Nix store.
# The package prefix inside Meson defaults to /usr. To copy a Nix
# build onto this machine under /usr, run scripts/install-local.sh.
{ pkgs ? import <nixpkgs> {} }:
pkgs.callPackage (
  { lib, stdenv, meson, ninja, pkg-config }:
  stdenv.mkDerivation {
    pname = "pixie";
    version = "0.1.0";
    src = lib.cleanSource ./.;
    nativeBuildInputs = [ meson ninja pkg-config ];
    meta = {
      description = "Package manager for Pixiewood pixie libraries";
      homepage = "https://github.com/roojs/pixie-pkg";
      license = lib.licenses.mit;
      mainProgram = "pixie";
      platforms = lib.platforms.all;
    };
  }
) {}
