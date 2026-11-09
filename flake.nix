{
  description = "pixie, the Pixiewood package manager";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      each = fn: nixpkgs.lib.genAttrs systems (system:
        fn (import nixpkgs { inherit system; })
      );
    in {
      packages = each (pkgs: {
        default = pkgs.callPackage ./default.nix { pkgs = pkgs; };
      });
    };
}
