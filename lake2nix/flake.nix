{
  description = "Convert Lean projects using Lake to Nix derivations";

  inputs.lean.url = github:leanprover/lean4;
  inputs.lake.url = github:leanprover/lake;
  inputs.lake.inputs.lean.follows = "lean";
  inputs.lake.inputs.flake-utils.follows = "lean/flake-utils";
  inputs.lake.inputs.nixpkgs.follows = "lean/nixpkgs";

  outputs = { self, lean, lake, flake-utils }: let
    outs = flake-utils.lib.eachDefaultSystem (system:
    with lean.packages.${system}.nixpkgs;
    let
      leanPkgs = lean.packages.${system};
      Lake = lake.packages.${system};
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
        lake2pkg = { config, deps, src, lean }: (leanPkgs.buildLeanPackage.override { inherit lean; }) {
          inherit (config) name libName;
          inherit deps;
          src = "${src}/${config.srcDir}";
          roots = config.globs;
          leanFlags = config.moreLeanArgs;
          leancFlags = config.moreLeancArgs;
          linkFlags =
            lib.optionalAttrs (!stdenv.hostPlatform.isWindows && config.supportInterpreter) ["-rdynamic"] ++
            config.moreLinkArgs;
        };
        lakeRepo2pkgs = { src, leanPkgs ? leanPkgs }: let
          json = runCommandNoCC "${src}-config" {} ''
            ${lake-export}/bin/lake-export ${src} > $out
          '';
          root = builtins.traceVerbose "loading Lake config from ${json}"
            (builtins.fromJSON (builtins.readFile json)).root;
          mkPkg = config: lake2pkg { inherit src config; inherit (leanPkgs) lean; deps = leanPkgs.stdlib; /* TODO */ };
          libs = lib.mapAttrs (_: cfg: mkPkg (root.config // cfg)) root.leanLibConfigs;
          exes = lib.mapAttrs (_: cfg: (mkPkg (root.config // cfg // { globs = [ cfg.root ]; })).override {
            executableName = cfg.exeName;
            deps = leanPkgs.stdlib ++ builtins.attrValues libs; /* TODO */
          }) root.leanExeConfigs;
          packages = lib.mapAttrs (_: l: l.modRoot) libs // lib.mapAttrs (_: e: e.executable) exes;
        in
          packages // { default = pkgs.linkFarm "{name}-default" (map (tgt: { name = tgt; path = packages.${tgt}; }) root.defaultTargets); };
      };

      defaultPackage = packages.lake-export;
    });
  in
    outs // {
      lib.lakeRepo2flake = cfg:
        flake-utils.lib.eachDefaultSystem (system: rec {
          packages = outs.packages.${system}.lakeRepo2pkgs (cfg // (if cfg ? leanPkgs then { leanPkgs = cfg.leanPkgs.${system}; } else {}));
        });
    };
}
