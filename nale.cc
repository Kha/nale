#include <filesystem>
#include <iostream>
#include <fstream>

#define SYSTEM "dummy"
#include <nix/fetchers.hh>
#include <nix/command.hh>
#include <nix/flake/flake.hh>
#include <nix/flake/flakeref.hh>
#include <nix/archive.hh>
#include <nix/store-api.hh>
#include <nix/globals.hh>
#include <nlohmann/json.hpp>

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
        std::string depInputs = "";
        std::string deps = "";
        std::ifstream manifestStream((tmpDir + "/lean_packages/manifest.json").c_str());
        if (manifestStream) {
            auto manifest = nlohmann::json::parse(manifestStream);
            for (auto pkg : manifest["packages"]) {
                std::string name = pkg["name"];
                std::string rev = pkg["rev"];
                std::string url = "git:";
                url += pkg["url"];
                std::string prefix = "git:https://github.com/";
                if (url.compare(0, prefix.size(), prefix) == 0) {
                    url.replace(0, prefix.size(), "github:");
                }
                depInputs += (format("  inputs.%1%.url = nale+%2%/%3%;\n  inputs.%1%.inputs.lean.follows = \"lean\";\n") %
                    name % url % rev).str();
                deps += (format("inputs.%1%") % name).str();
            }
        }
        auto flakeContents = format(R"({
  inputs.lean.url = github:%1%;
  inputs.lake2nix.url = @lake2nix-url@;
    #inputs.lake2nix.inputs.lean.follows = "lean";
%2%
  outputs = inputs: inputs.lake2nix.lib.lakeRepo2flake { src = ./.; leanPkgs = inputs.lean.packages; deps = [ %3% ]; };
})") % leanVersion % depInputs % deps;
        writeFile(tmpDir + "/flake.nix", flakeContents.str());
        // creating new EvalState segfaults?
        //auto state = std::shared_ptr<EvalState>(new EvalState({}, store));
        //nix::flake::lockFlake(globals.state, parseFlakeRef(".", tmpDir), {}).lockFile.write(tmpDir + "/flake.lock");
        runProgram(getEnv("NALE_NIX_SELF").value_or("nix"), false, {"--quiet", "flake", "lock", tmpDir});

        auto storePath = store->addToStore("source.nale", tmpDir, FileIngestionMethod::Recursive, htSHA256, defaultPathFilter);
        input2.attrs["nested_type"] = input2.attrs["type"];
        input2.attrs["type"] = "nale";
        input2.attrs.erase("narHash");
        return std::make_pair(storePath, input2);
    };
};

static auto rNaleInputScheme = OnStartup([] { registerInputScheme(std::make_unique<NaleInputScheme>()); });

}
