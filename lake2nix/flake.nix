{
  description = "Convert Lean projects using Lake to Nix derivations";

  inputs.lean.url = github:Kha/lean4/nix-lake;
  inputs.lake.url = github:leanprover/lake;
  inputs.lake.inputs.lean.follows = "lean";
  inputs.lake.inputs.flake-utils.follows = "lean/flake-utils";
  inputs.lake.inputs.nixpkgs.follows = "lean/nixpkgs";
  inputs.flake-utils.follows = "lean/flake-utils";

  outputs = { self, lean, lake, flake-utils }: let
    outs = flake-utils.lib.eachDefaultSystem (system:
    with lean.packages.${system}.nixpkgs;
    let
      leanPkgs = lean.packages.${system};
      Lake = lake.packages.${system}.Lake;
      LakeExport = leanPkgs.buildLeanPackage {
        name = "LakeExport";  # must match the name of the top-level .lean file
        deps = [ Lake ];
        src = ./.;
        linkFlags = lib.optionalAttrs (!stdenv.hostPlatform.isWindows) [ "-rdynamic" ];
      };
    in rec {
      packages = LakeExport // rec {
        inherit (leanPkgs) lean;
        lake-export = writeShellScriptBin "lake-export" ''
          LEAN_PATH=${Lake.modRoot} exec ${LakeExport.executable}/bin/lakeexport "$@"
        '';
        lake2pkg = { config, deps, src, lean }: let
          pkg = (leanPkgs.buildLeanPackage.override { inherit lean; }) {
            inherit (config) name libName binName binRoot;
            inherit deps;
            src = "${src}/${config.srcDir}";
            libRoots = config.libGlobs;
            leanFlags = config.moreLeanArgs;
            leancFlags = config.moreLeancArgs;
            linkFlags =
              lib.optionalAttrs (!stdenv.hostPlatform.isWindows && config.supportInterpreter) ["-rdynamic"] ++
              config.moreLinkArgs;
            # TODO (unused): moreServerArgs
            # uninteresting(?): buildDir, oleanDir, irDir, libDir, binDir
            # programs missing from export: moreLibTargets, scripts, extraDepTarget
          };
        in
          pkg // {
            default = {
              bin = pkg.executable;
              staticLib = pkg.staticLib;
              sharedLib = pkg.sharedLib;
              oleans = pkg.modRoot;
            }."${config.defaultFacet}";
          };
        lakeRepo2pkg = { src, leanPkgs ? leanPkgs }: let
          json = runCommandNoCC "${src}-config" {} ''
            ${lake-export}/bin/lake-export ${src} > $out
          '';
          config = builtins.fromJSON (builtins.readFile json);
        in
          lake2pkg { inherit config src; inherit (leanPkgs) lean; deps = leanPkgs.stdlib; };
      };

      defaultPackage = packages.lake-export;
    });
  in
    outs // {
      lib.lakeRepo2flake = cfg:
        flake-utils.lib.eachDefaultSystem (system: rec {
          packages = outs.packages.${system}.lakeRepo2pkg (cfg // (if cfg ? leanPkgs then { leanPkgs = cfg.leanPkgs.${system}; } else {}));
        });
    };
}
