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
#include <nix/cache.hh>
#include <nix/fs-input-accessor.hh>
#include <nlohmann/json.hpp>

namespace nix::fetchers {

std::string naleVersion = "nale-v1";

struct OverlayAccessor : InputAccessor
{
    ref<InputAccessor> first;
    ref<InputAccessor> second;

    OverlayAccessor(ref<InputAccessor> first, ref<InputAccessor> second)
        : first(first)
        , second(second)
    {
    }

    std::string readFile(const CanonPath & path) override
    {
        return first->pathExists(path) ? first->readFile(path) : second->readFile(path);
    }

    bool pathExists(const CanonPath & path) override
    {
        return first->pathExists(path) || second->pathExists(path);
    }

    Stat lstat(const CanonPath & path) override
    {
        return first->pathExists(path) ? first->lstat(path) : second->lstat(path);
    }

    DirEntries readDirectory(const CanonPath & path) override
    {
        DirEntries entries;
        if (second->pathExists(path))
            entries = second->readDirectory(path);
        if (first->pathExists(path))
            for (auto const & e : first->readDirectory(path))
                entries[e.first] = e.second;
        return entries;
    }

    std::string readLink(const CanonPath & path) override
    {
        return first->pathExists(path) ? first->readLink(path) : second->readLink(path);
    }

    std::string showPath(const CanonPath & path) override
    {
        return first->pathExists(path) ? first->showPath(path) : second->showPath(path);
    }
};

struct NaleInputScheme : InputScheme
{
    static Attrs wrapAttrs(Attrs attrs) {
        attrs["nested_type"] = attrs["type"];
        attrs["type"] = "nale";
        return attrs;
    }

    static Attrs unwrapAttrs(Attrs attrs) {
        attrs["type"] = attrs["nested_type"];
        attrs.erase("nested_type");
        return attrs;
    }

    std::optional<Input> inputFromURL(const ParsedURL & url) const override
    {
        auto url2(url);
        if (hasPrefix(url2.scheme, "nale+"))
            url2 = parseURL(std::string(url2.to_string(), 5));
        else
            return {};

        auto input = Input::fromURL(url2);
        input.attrs = wrapAttrs(input.attrs);

        return input;
    }

    std::optional<Input> inputFromAttrs(const Attrs & attrs) const override
    {
        if (maybeGetStrAttr(attrs, "type") != "nale") return {};

        //for (auto & [name, value] : attrs)
        //    if (name != "type" && name != "nested")
        //        throw Error("unsupported Nale input attribute '%s'", name);

        Input input = Input::fromAttrs(unwrapAttrs(attrs));
        input.attrs = wrapAttrs(input.attrs);

        return input;
    }

    ParsedURL toURL(const Input & input) const override
    {
        auto url = Input::fromAttrs(unwrapAttrs(input.attrs)).toURL();
        return parseURL("nale+" + url.to_string());
    }

    Input applyOverrides(
        const Input & input,
        std::optional<std::string> ref,
        std::optional<Hash> rev) const override
    {
        auto nested = Input::fromAttrs(unwrapAttrs(input.attrs));
        Input input2 = nested.applyOverrides(ref, rev);
        input2.attrs = wrapAttrs(input2.attrs);
        return input2;
    }

    void clone(const Input & input, const Path & destDir) const override
    {
        auto nested = Input::fromAttrs(unwrapAttrs(input.attrs));
        // TODO: patch here as well?
        nested.clone(destDir);
    }

    bool isLocked(const Input & input) const override
    {
        auto nested = Input::fromAttrs(unwrapAttrs(input.attrs));
        return nested.isLocked();
    }

    std::optional<std::string> isRelative(const Input & input) const override
    {
        auto nested = Input::fromAttrs(unwrapAttrs(input.attrs));
        return nested.isRelative();
    }

    std::optional<std::string> getFingerprint(ref<Store> store, const Input & input) const override
    {
        auto nested = Input::fromAttrs(unwrapAttrs(input.attrs));
        auto f = nested.getFingerprint(store);
        return f ? std::optional<std::string>(*f + getEnv("NALE_LAKE2NIX").value()) : std::nullopt;
    }

    nix::StorePath mkFlakeFiles(ref<Store> store, InputAccessor & acc) const
    {
        auto manifest = acc.pathExists(CanonPath("/lake-manifest.json")) ? acc.readFile(CanonPath("/lake-manifest.json")) : "";
        auto lakefile = acc.readFile(CanonPath("/lakefile.lean"));
        auto leanVersion = chomp(acc.readFile(CanonPath("/lean-toolchain")));
        Attrs lockedAttrs;
        lockedAttrs["manifest"] = manifest;
        lockedAttrs["lakefile"] = lakefile;
        lockedAttrs["leanVersion"] = leanVersion;
        lockedAttrs["naleVersion"] = naleVersion;
        lockedAttrs["lake2nixVersion"] = getEnv("NALE_LAKE2NIX").value();

        if (auto res = getCache()->lookup(store, lockedAttrs))
            return std::move(res->second);

        Path tmpDir = createTempDir();
        AutoDelete delTmpDir(tmpDir, true);

        {
            std::ofstream s(tmpDir + "/lakefile.lean");
            s << lakefile;
        }

        if (chmod(tmpDir.c_str(), 0777) == -1)
            throw SysError("changing permissions on '%1%'", tmpDir);

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
        if (manifest.size()) {
            auto json = nlohmann::json::parse(manifest);
            for (auto pkg : json["packages"]) {
                if (!pkg.contains("git"))
                    throw Error("unhandled input scheme '%s'", *pkg.begin());
                pkg = pkg["git"];
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
                deps += (format("inputs.%1% ") % name).str();
            }
        }
        auto flakeContents = format(R"({
  inputs.lean.url = github:%1%;
  inputs.lake2nix.url = %2%;
    #inputs.lake2nix.inputs.lean.follows = "lean";
%3%
  outputs = inputs: inputs.lake2nix.lib.lakeRepo2flake { src = ./.; leanPkgs = inputs.lean.packages; depFlakes = [ %4% ]; };
})") % leanVersion % getEnv("NALE_LAKE2NIX").value() % depInputs % deps;
        writeFile(tmpDir + "/flake.nix", flakeContents.str());
        // creating new EvalState segfaults?
        //auto state = std::shared_ptr<EvalState>(new EvalState({}, store));
        //nix::flake::lockFlake(globals.state, parseFlakeRef(".", tmpDir), {}).lockFile.write(tmpDir + "/flake.lock");
        runProgram(getEnv("NALE_NIX_SELF").value_or("nix"), false, {"--quiet", "flake", "lock", tmpDir});

        auto storePath = store->addToStore("source.nale", tmpDir, FileIngestionMethod::Recursive, htSHA256, defaultPathFilter);
        getCache()->add(
            store,
            lockedAttrs,
            {},
            storePath,
            true);


        return storePath;
    }

    std::pair<ref<InputAccessor>, Input> getAccessor(ref<Store> store, const Input & input) const override
    {
        auto nested = Input::fromAttrs(unwrapAttrs(input.attrs));
        auto [acc, input2] = nested.getAccessor(store);
        auto flakeFiles = mkFlakeFiles(store, *acc);
        input2.attrs = wrapAttrs(input2.attrs);
        return {make_ref<OverlayAccessor>(makeStorePathAccessor(store, flakeFiles), acc), input2};
    }
};

static auto rNaleInputScheme = OnStartup([] { registerInputScheme(std::make_unique<NaleInputScheme>()); });

}
