{
  description = "Lean + Nix";

  inputs.nixpkgs.url = github:NixOS/nixpkgs/nixpkgs-unstable;
  inputs.flake-utils.url = github:numtide/flake-utils;
  inputs.nix.url = github:Kha/nix/nale;
  inputs.lake2nix.url = "path:./lake2nix";

  outputs = inputs:
    inputs.flake-utils.lib.eachDefaultSystem (system: with inputs.nixpkgs.legacyPackages.${system}; {
      packages = rec {
        nix = inputs.nix.packages.${system}.nix;
        #nix = (pkg: pkg.overrideAttrs (_: { stdenv = stdenvAdapters.keepDebugInfo pkg.stdenv; separateDebugInfo = false; NIX_CFLAGS_COMPILE = " -ggdb -Og"; dontStrip = true; })) inputs.nix.packages.${system}.nix;
        nale-plugin = stdenv.mkDerivation {
          name ="nale-plugin";
          src = builtins.path { name = "nale.cc"; path = ./.; filter = p: _: p == toString ./nale.cc; };
          buildInputs = [ nix.dev ] ++ nix.buildInputs;
          buildPhase = ''
            mkdir $out
            c++ -shared -o $out/nale.so nale.cc -std=c++17 -I ${nix.dev}/include/nix -O0 -g
          '';
          dontInstall = true;
        };
        nix-nale = writeShellScriptBin "nix" ''
          NALE_NIX_SELF=$BASH_SOURCE NALE_LAKE2NIX=path:${inputs.lake2nix}?narHash=${inputs.lake2nix.narHash} ''${NALE_NIX_PREFIX:-} ''${NALE_NIX:-${nix}/bin/nix} --extra-plugin-files ${nale-plugin}/nale.so --experimental-features 'nix-command flakes' --extra-substituters https://lean4.cachix.org/ --option warn-dirty false "$@"
        '';
      };
    });
}
