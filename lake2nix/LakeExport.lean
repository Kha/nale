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
    let ws ← loadWorkspace.{0} { env := (← Env.compute lakeInstall?.get! leanInstall?.get!), rootDir := args[0]! }
    -- remove forbidden /nix/store references
    let undir pkg := { pkg with dir := "" }
    let ws := { ws with root := undir ws.root, packageMap := ws.packageMap.fold (init := {}) (·.insert · <| undir ·) }
    IO.println (toJson ws).compress).run
