{
  description = "Convert Lean projects using Lake to Nix derivations";

  inputs.lean.url = github:leanprover/lean4;
  inputs.lake.url = github:leanprover/lake/lean4-master;
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
          src = src + "/${config.srcDir}";
          roots = config.globs;
          leanFlags = config.moreLeanArgs;
          leancFlags = config.moreLeancArgs;
          linkFlags =
            lib.optional (!stdenv.hostPlatform.isWindows && config.supportInterpreter or false) "-rdynamic" ++
            config.moreLinkArgs;
        };
        lakeRepo2pkgs = { name, src, leanPkgs ? leanPkgs, deps ? [] }: let
          lake-src = builtins.filterSource (e: _: baseNameOf e == "lakefile.lean" || baseNameOf e == "lake-manifest.json") src;
          json = runCommandNoCC "lake-export-json" {} ''
            ${lake-export}/bin/lake-export ${lake-src} > $out
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
          { ${name} = packages // { default = pkgs.linkFarm "${root.config.name}-default" (map (tgt: { name = tgt; path = packages.${tgt}.outPath; }) root.defaultTargets); }; };
      };

      defaultPackage = packages.lake-export;
    });
  in
    outs // {
      lib.lakeRepo2flake = { name, src, lean, depFlakes }:
        let lib = lean.packages.x86_64-linux.nixpkgs.lib; in
        { inherit name; } //
        flake-utils.lib.eachDefaultSystem (system:
          let flake = rec {
            overlay = self: super: outs.packages.${system}.lakeRepo2pkgs {
              inherit name src;
              deps = builtins.concatMap (d: self.${d.name}.deps) depFlakes;
              leanPkgs = super;
            };
            overlays = builtins.concatMap (d: d.overlays.${system}) depFlakes ++ [overlay];

            packages =
              let toFix = lib.foldl' (lib.flip lib.extends) (self: lean.packages.${system}) overlays; in
              (lib.fix toFix).${name};
          };
          in
            if builtins.pathExists (src + "/nale.nix") then
              let flake' = lib.makeExtensible (_: flake);
                  extends = (import (src + "/nale.nix") { inherit system; }).extends or (_: _: {}); in
                flake'.extend extends
            else
              flake
        );
    };
}
