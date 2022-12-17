{
  description = "Lean + Nix";

  inputs.nixpkgs.url = github:NixOS/nixpkgs/nixpkgs-unstable;
  inputs.nixpkgs.follows = "nix/nixpkgs";
  inputs.flake-utils.url = github:numtide/flake-utils;
  inputs.nix.url = github:Kha/nix/nale;
  inputs.nix-portable.url = github:Kha/nix-portable/nale;
  inputs.nix-portable.inputs.nixpkgs.follows = "nix/nixpkgs";
  inputs.lake2nix.url = github:Kha/nale?dir=lake2nix;

  outputs = inputs:
    inputs.flake-utils.lib.eachDefaultSystem (system: with inputs.nixpkgs.legacyPackages.${system}; {
      packages = rec {
        nix = inputs.nix.packages.${system}.nix;
        #nix = (pkg: pkg.overrideAttrs (_: { stdenv = stdenvAdapters.keepDebugInfo pkg.stdenv; separateDebugInfo = false; NIX_CFLAGS_COMPILE = " -ggdb -Og"; dontStrip = true; })) inputs.nix.packages.${system}.nix;
        nale-plugin = runCommandCC "nale-plugin" { buildInputs = [ nix.dev ] ++ nix.buildInputs; } ''
          mkdir $out
          c++ -shared -o $out/nale.so ${./nale.cc} -std=c++17 -I ${nix.dev}/include/nix -O2
        '';
        nix-nale = writeShellScriptBin "nix" ''
          NIX_USER_CONF_FILES= \
          NALE_NIX_SELF=$BASH_SOURCE \
          NALE_LAKE2NIX=''${NALE_LAKE2NIX:-'github:Kha/nale/${ inputs.lake2nix.rev }?dir=lake2nix'} \
          exec ''${NALE_NIX_PREFIX:-} ''${NALE_NIX:-${nix}/bin/"$(basename "$0")"} \
            --option extra-plugin-files ${nale-plugin}/nale.so \
            "$@"
        '';
        nix-nale-bundle = symlinkJoin { name = "nix-nale-bundle"; paths = [ nix-nale nix ]; };
        nix-nale-portable = inputs.nix-portable.packages.${system}.nix-portable.override {
          nix = nix-nale-bundle;
          extraNixConf = ''
            max-jobs = auto
            http-connections = 300  # important for multiplexing throughput
            keep-outputs = true
            extra-substituters = https://lean4.cachix.org/
            extra-trusted-public-keys = lean4.cachix.org-1:mawtxSxcaiWE24xCXXgh3qnvlTkyU7evRRnGeAhD4Wk=
            experimental-features = nix-command flakes
            warn-dirty = false
          '';
        };
        default = nix-nale-portable;
        inherit (inputs.lake2nix.packages.${system}) ciShell;
      };
    });
}
