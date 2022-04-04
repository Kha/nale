import Lake

open Lake
open Lean

deriving instance ToJson for Source
deriving instance ToJson for Dependency
instance : ToJson Glob where
  toJson
    | Glob.one n => Json.obj (Std.RBNode.singleton "mod" (toJson n) |>.insert compare "glob" "one")
    | Glob.submodules n => Json.obj (Std.RBNode.singleton "mod" (toJson n) |>.insert compare "glob" "submodules")
    | Glob.andSubmodules n => Json.obj (Std.RBNode.singleton "mod" (toJson n) |>.insert compare "glob" "andSubmodules")
deriving instance ToJson for PackageFacet
instance : ToJson OpaqueTarget := ⟨fun _ => Json.str "unimplemented"⟩
instance : ToJson FileTarget := ⟨fun _ => Json.str "unimplemented"⟩
instance : ToJson Script := ⟨fun _ => Json.str "unimplemented"⟩
instance [ToJson α] : ToJson (NameMap α) where
  toJson m := Json.obj <| m.fold (init := Std.RBNode.leaf) fun m k v =>
    m.insert compare k.toString (toJson v)
deriving instance ToJson for PackageConfig

def main (args : List String) : IO Unit := do
  initSearchPath "."
  let pkg ← Package.load (args.get! 0)
  IO.println (toJson pkg.config).compress
