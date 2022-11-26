{
  description = "Lean + Nix";

  inputs.nixpkgs.url = github:NixOS/nixpkgs/nixpkgs-unstable;
  inputs.flake-utils.url = github:numtide/flake-utils;
  inputs.nix.url = github:Kha/nix/nested-follows2;

  outputs = inputs:
    inputs.flake-utils.lib.eachDefaultSystem (system: with inputs.nixpkgs.legacyPackages.${system}; {
      packages = rec {
        nix = (pkg: pkg.overrideAttrs (_: { stdenv = stdenvAdapters.keepDebugInfo pkg.stdenv; })) inputs.nix.packages.${system}.nix;
        nale-plugin = stdenv.mkDerivation {
          name ="nale-plugin";
          src = builtins.path { name = "nale.cc"; path = ./.; filter = p: _: p == toString ./nale.cc; };
          buildInputs = [ nix.dev ] ++ nix.buildInputs;
          buildPhase = ''
            mkdir $out
            substituteInPlace nale.cc --replace '@lake2nix-url@' 'path:${./lake2nix}'
            c++ -shared -o $out/nale.so nale.cc -std=c++17 -I ${nix.dev}/include/nix -O0 -g
          '';
          dontInstall = true;
        };
        nix-nale = writeShellScriptBin "nix" ''
          NALE_NIX_SELF=$BASH_SOURCE ''${NALE_NIX_PREFIX:-} ''${NALE_NIX:-${nix}/bin/nix} --extra-plugin-files ${nale-plugin}/nale.so --experimental-features 'nix-command flakes' --extra-substituters https://lean4.cachix.org/ --option warn-dirty false "$@"
        '';
      };
    });
}
