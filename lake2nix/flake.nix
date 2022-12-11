{
  description = "Convert Lean projects using Lake to Nix derivations";

  inputs.lean.url = github:leanprover/lean4;
  inputs.lake.url = github:leanprover/lake;
  inputs.lake.flake = false;

  outputs = { self, lean, lake, flake-utils }: let
    outs = flake-utils.lib.eachDefaultSystem (system:
    with lean.packages.${system}.nixpkgs;
    let
      leanPkgs = lean.packages.${system};
      Lake = leanPkgs.buildLeanPackage {
        name = "Lake";
        src = lake;
        roots = [ { mod = "Lake"; glob = "andSubmodules"; } ];
      };
      LakeExport = leanPkgs.buildLeanPackage {
        name = "LakeExport";
        deps = [ Lake ];
        src = ./.;
        linkFlags = lib.optional (!stdenv.hostPlatform.isWindows) "-rdynamic";
      };
    in rec {
      packages = LakeExport // rec {
        inherit (leanPkgs) lean lean-all ciShell;
        lake-export = writeShellScriptBin "lake-export" ''
          LEAN_PATH=${Lake.modRoot} exec ${LakeExport.executable}/bin/lakeexport "$@"
        '';
        lake2pkg = { config, deps, src, leanPkgs ? leanPkgs }: leanPkgs.buildLeanPackage {
          inherit (config) name libName;
          inherit deps;
          src = "${src}/${config.srcDir}";
          roots = config.globs;
          leanFlags = config.moreLeanArgs;
          leancFlags = config.moreLeancArgs;
          linkFlags =
            lib.optional (!stdenv.hostPlatform.isWindows && config.supportInterpreter or false) "-rdynamic" ++
            config.moreLinkArgs;
        };
        lakeRepo2pkgs = { src, leanPkgs ? leanPkgs, deps ? [] }: let
          json = runCommandNoCC "${src}-config" {} ''
            ${lake-export}/bin/lake-export ${src} > $out
          '';
          root = builtins.traceVerbose "loading Lake config from ${json}"
            (builtins.fromJSON (builtins.readFile json)).root;
          mkPkg = config: lake2pkg { inherit src config leanPkgs; deps = leanPkgs.stdlib ++ deps; };
          libs = lib.mapAttrs (_: cfg: mkPkg (root.config // cfg)) root.leanLibConfigs;
          exes = lib.mapAttrs (_: cfg: (mkPkg (root.config // cfg // { globs = [ cfg.root ]; })).override {
            executableName = cfg.exeName;
            deps = leanPkgs.stdlib ++ deps ++ builtins.attrValues libs;
          }) root.leanExeConfigs;
          packages = lib.mapAttrs (_: l: l.modRoot // l) libs // { deps = lib.attrValues libs; } // lib.mapAttrs (_: e: e.executable // e) exes;
        in
          packages // { default = pkgs.linkFarm "${root.config.name}-default" (map (tgt: { name = tgt; path = packages.${tgt}.outPath; }) root.defaultTargets); };
      };

      defaultPackage = packages.lake-export;
    });
  in
    outs // {
      lib.lakeRepo2flake = { src, leanPkgs ? lean.packages, depFlakes ? [] }:
        flake-utils.lib.eachDefaultSystem (system: rec {
          packages = outs.packages.${system}.lakeRepo2pkgs {
            inherit src;
            deps = builtins.concatMap (flake: flake.packages.${system}.deps) depFlakes;
            leanPkgs = leanPkgs.${system};
          };
        });
    };
}
