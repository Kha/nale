import Lake

open Lake
open Lean

instance [ToJson α] : ToJson (NameMap α) where
  toJson nm := Json.obj <| nm.fold (init := Std.RBNode.leaf) (fun n k v => n.insert compare k.toString (toJson v))

deriving instance ToJson for Source
deriving instance ToJson for Dependency
instance : ToJson Glob where
  toJson
    | Glob.one n => Json.obj (Std.RBNode.singleton "mod" (toJson n) |>.insert compare "glob" "one")
    | Glob.submodules n => Json.obj (Std.RBNode.singleton "mod" (toJson n) |>.insert compare "glob" "submodules")
    | Glob.andSubmodules n => Json.obj (Std.RBNode.singleton "mod" (toJson n) |>.insert compare "glob" "andSubmodules")
instance : ToJson Script := ⟨fun _ => Json.str "unimplemented"⟩
instance [ToJson α] : ToJson (NameMap α) where
  toJson m := Json.obj <| m.fold (init := Std.RBNode.leaf) fun m k v =>
    m.insert compare k.toString (toJson v)
deriving instance ToJson for BuildType
deriving instance ToJson for PackageConfig
instance : ToJson (ModuleFacet α) := ⟨fun _ => Json.str "unimplemented"⟩
deriving instance ToJson for LeanLibConfig
deriving instance ToJson for LeanExeConfig
instance : ToJson Environment := ⟨fun _ => Json.str "unimplemented"⟩
instance : ToJson Options := ⟨fun _ => Json.str "unimplemented"⟩
instance : ToJson OpaquePackage := ⟨fun _ => Json.str "unimplemented"⟩
instance : ToJson (DNameMap s) := ⟨fun _ => Json.str "unimplemented"⟩
deriving instance ToJson for Package
instance : ToJson Env := ⟨fun _ => Json.str "unimplemented"⟩
deriving instance ToJson for Workspace

def main (args : List String) : IO UInt32 := do
  initSearchPath "."
  let (leanInstall?, lakeInstall?) ← findInstall?
  (MainM.runLogIO do
    let config := { env := (← Env.compute lakeInstall?.get! leanInstall?.get!), rootDir := args[0]! : LoadConfig.{0} }
    --let ws ← loadWorkspace.{0} config
    -- same as `loadWorkspace`, but without invoking `git`
    let ws ← do
      Lean.searchPathRef.set config.env.leanSearchPath
      let configEnv ← elabConfigFile config.rootDir config.configOpts config.leanOpts config.configFile
      let pkgConfig ← IO.ofExcept <| PackageConfig.loadFromEnv configEnv config.leanOpts
      let repo := GitRepo.mk config.rootDir
      let root : Package := {
        configEnv, leanOpts := config.leanOpts
        dir := config.rootDir, config := pkgConfig
      }
      let ws : Workspace := {
        root, lakeEnv := config.env
        moduleFacetConfigs := initModuleFacetConfigs
        packageFacetConfigs := initPackageFacetConfigs
        libraryFacetConfigs := initLibraryFacetConfigs
      }
      ws.finalize
      -- avoid manifest write
      --let root ← root.resolveDeps config.updateDeps
      --{ws with root}.finalize
    -- remove forbidden /nix/store references
    let undir pkg := { pkg with dir := "" }
    let ws := { ws with root := undir ws.root, packageMap := ws.packageMap.fold (init := {}) (·.insert · <| undir ·) }
    IO.println (toJson ws).compress).run
