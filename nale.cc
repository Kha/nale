#include <filesystem>
#include <iostream>

#include <nix/fetchers.hh>
#include <nix/archive.hh>
#define SYSTEM "dummy"
#include <nix/store-api.hh>

namespace nix::fetchers {

struct NaleInputScheme : InputScheme
{
    std::optional<Input> inputFromURL(const ParsedURL & url) override
    {
        auto url2(url);
        if (hasPrefix(url2.scheme, "nale+"))
            url2.scheme = std::string(url2.scheme, 5);
        else
            return {};

        auto input = Input::fromURL(url2);
        input.attrs["nested_type"] = input.attrs["type"];
        input.attrs["type"] = "nale";

        return input;
    }

    Attrs unwrapAttrs(const Attrs & _attrs) {
        Attrs attrs(_attrs);
        attrs["type"] = attrs["nested_type"];
        attrs.erase("nested_type");
        return attrs;
    }

    std::optional<Input> inputFromAttrs(const Attrs & attrs) override
    {
        if (maybeGetStrAttr(attrs, "type") != "nale") return {};

        //for (auto & [name, value] : attrs)
        //    if (name != "type" && name != "nested")
        //        throw Error("unsupported Nale input attribute '%s'", name);

        Input input = Input::fromAttrs(unwrapAttrs(attrs));

        Input input2;
        input2.attrs = attrs;
        return input;
    }

    ParsedURL toURL(const Input & input) override
    {
        auto url = Input::fromAttrs(unwrapAttrs(input.attrs)).toURL();
        url.scheme = "nale+" + url.scheme;
        return url;
    }

    bool hasAllInfo(const Input & input) override
    {
        auto nested = Input::fromAttrs(unwrapAttrs(input.attrs));
        return nested.hasAllInfo();
    }

    Input applyOverrides(
        const Input & input,
        std::optional<std::string> ref,
        std::optional<Hash> rev) override
    {
        auto nested = Input::fromAttrs(unwrapAttrs(input.attrs));
        Input input2 = nested.applyOverrides(ref, rev);
        input2.attrs["nested_type"] = input2.attrs["type"];
        input2.attrs["type"] = "nale";

        return input2;
    }

    void clone(const Input & input, const Path & destDir) override
    {
        auto nested = Input::fromAttrs(unwrapAttrs(input.attrs));
        // TODO: patch here as well?
        nested.clone(destDir);
    }

    std::optional<Path> getSourcePath(const Input & input) override
    {
        auto nested = Input::fromAttrs(unwrapAttrs(input.attrs));
        return nested.getSourcePath();
    }

    void markChangedFile(const Input & input, std::string_view file, std::optional<std::string> commitMsg) override
    {
        auto nested = Input::fromAttrs(unwrapAttrs(input.attrs));
        nested.markChangedFile(file, commitMsg);
    }

    std::pair<nix::StorePath, Input> fetch(ref<Store> store, const Input & input) override
    {
        auto nested = Input::fromAttrs(unwrapAttrs(input.attrs));
        auto [tree, input2] = nested.fetch(store);

        Path tmpDir = createTempDir();
        AutoDelete delTmpDir(tmpDir, true);

        runProgram2({ .program = "cp", .searchPath = true, .args = { "-r", tree.actualPath + "/.", tmpDir } });
        //copyPath(tree.actualPath, tmpDir);
        //std::filesystem::remove(tmpDir);
        //std::filesystem::copy(tree.actualPath, tmpDir, std::filesystem::copy_options::recursive);

        if (chmod(tmpDir.c_str(), 0777) == -1)
            throw SysError("changing permissions on '%1%'", tmpDir);

        auto leanVersion = chomp(readFile(tmpDir + "/lean-toolchain"));
        auto nightlySpec = ":nightly";
        auto off = leanVersion.find(nightlySpec);
        if (off != std::string::npos) {
            // `leanprover/lean4` ~> `leanprover/lean4-nightly`
            leanVersion.insert(off, "-nightly");
        }
        off = leanVersion.find(':');
        if (off != std::string::npos) {
            leanVersion[off] = '/';
        }
        auto flakeContents = format(R"({
  inputs.lean.url = github:%1%;
  inputs.lake2nix.url = @lake2nix-url@;
  inputs.lake2nix.inputs.lean.follows = "lean";

  outputs = { self, lake2nix, lean, ... }: lake2nix.lib.lakeRepo2flake { src = ./.; leanPkgs = lean.packages; };
})") % leanVersion;
        writeFile(tmpDir + "/flake.nix", flakeContents.str());
        //nix::flake::lockFlake(EvalState(searchPath, store), parseFlakeRef(".", tmpDir), {});
        auto self_path = readLink("/proc/self/exe");
        runProgram(self_path, false, {"--quiet", "flake", "lock", tmpDir});

        auto storePath = store->addToStore("source.nale", tmpDir, FileIngestionMethod::Recursive, htSHA256, defaultPathFilter);
        input2.attrs["nested_type"] = input2.attrs["type"];
        input2.attrs["type"] = "nale";
        input2.attrs.erase("narHash");
        return std::make_pair(storePath, input2);
    };
};

static auto rNaleInputScheme = OnStartup([] { registerInputScheme(std::make_unique<NaleInputScheme>()); });

}
