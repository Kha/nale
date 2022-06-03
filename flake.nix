{
  description = "Lean + Nix";

  inputs.nixpkgs.url = github:NixOS/nixpkgs/nixpkgs-unstable;
  inputs.flake-utils.url = github:numtide/flake-utils;
  inputs.nix.url = github:NixOS/nix;

  outputs = inputs:
    inputs.flake-utils.lib.eachDefaultSystem (system: with inputs.nixpkgs.legacyPackages.${system}; let
      nix = inputs.nix.packages.${system}.nix; in {
      packages = rec {
        nale-plugin = stdenv.mkDerivation {
          name ="nale-plugin";
          src = ./.;
          buildInputs = [ nix.dev ] ++ nix.buildInputs;
          buildPhase = ''
            mkdir $out
            substituteInPlace nale.cc --replace '@lake2nix-url@' 'path:${./lake2nix}'
            c++ -shared -o $out/nale.so nale.cc -std=c++17 -I ${nix.dev}/include/nix
          '';
          dontInstall = true;
        };
        nix-nale = writeShellScriptBin "nix" ''
          ''${NALE_NIX:-${nix}/bin/nix} --experimental-features 'nix-command flakes' --extra-plugin-files ${nale-plugin}/nale.so --extra-substituters https://lean4.cachix.org/ --option warn-dirty false "$@"
        '';
      };
    });
}
