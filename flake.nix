{
  description = "Lean + Nix";

  inputs.nixpkgs.url = github:NixOS/nixpkgs/nixpkgs-unstable;
  inputs.flake-utils.url = github:numtide/flake-utils;
  inputs.nix.url = github:NixOS/nix;

  outputs = { self, nixpkgs, flake-utils, nix }:
    flake-utils.lib.eachDefaultSystem (system: with nixpkgs.legacyPackages.${system}; {
      packages = {
        nale-plugin = runCommandCC "nale-plugin" {} ''
          mkdir $out
          c++ -shared -I ${nix.packages.${system}.nix.dev}/include/nix -o $out/nale.so ${./nale.cc} -v
        '';
      };
    });
}
