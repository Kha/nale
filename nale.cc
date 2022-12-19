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
    static Attrs mergeAttrs(Attrs nested, Attrs ours) {
        nested["nested_type"] = nested["type"];
        nested["type"] = "nale";
        for (auto const & p : ours)
            nested[p.first] = p.second;
        return nested;
    }

    static std::pair<Attrs, Attrs> splitAttrs(Attrs attrs) {
        attrs["type"] = attrs["nested_type"];
        attrs.erase("nested_type");
        Attrs ours;
        if (attrs.count("leanVersion")) {
            ours["leanVersion"] = attrs["leanVersion"];
            attrs.erase("leanVersion");
        }
        return {attrs, ours};
    }

    std::optional<Input> inputFromURL(const ParsedURL & url) const override
    {
        auto url2(url);
        if (hasPrefix(url2.scheme, "nale+"))
            url2.scheme = std::string(url2.scheme, 5);
        else
            return {};

        Attrs ours;
        if (url2.query.count("leanVersion")) {
            ours.insert_or_assign("leanVersion", url2.query["leanVersion"]);
            url2.query.erase("leanVersion");
        }
        auto input = Input::fromURL(url2);
        input.attrs = mergeAttrs(input.attrs, ours);
        return input;
    }

    std::optional<Input> inputFromAttrs(const Attrs & attrs) const override
    {
        if (maybeGetStrAttr(attrs, "type") != "nale") return {};

        //for (auto & [name, value] : attrs)
        //    if (name != "type" && name != "nested")
        //        throw Error("unsupported Nale input attribute '%s'", name);

        auto [nested, ours] = splitAttrs(attrs);
        Input input = Input::fromAttrs(std::move(nested));
        input.attrs = mergeAttrs(input.attrs, ours);
        return input;
    }

    ParsedURL toURL(const Input & input) const override
    {
        auto [nested, ours] = splitAttrs(input.attrs);
        auto url = Input::fromAttrs(std::move(nested)).toURL();
        url.scheme = "nale+" + url.scheme;
        return url;
    }

    Input applyOverrides(
        const Input & input,
        std::optional<std::string> ref,
        std::optional<Hash> rev) const override
    {
        auto [nested, ours] = splitAttrs(input.attrs);
        auto input2 = Input::fromAttrs(std::move(nested));
        input2 = input2.applyOverrides(ref, rev);
        input2.attrs = mergeAttrs(input2.attrs, ours);
        return input2;
    }

    void clone(const Input & input, const Path & destDir) const override
    {
        auto nested = Input::fromAttrs(splitAttrs(input.attrs).first);
        // TODO: patch here as well?
        nested.clone(destDir);
    }

    bool isLocked(const Input & input) const override
    {
        auto nested = Input::fromAttrs(splitAttrs(input.attrs).first);
        return nested.isLocked();
    }

    std::optional<std::string> isRelative(const Input & input) const override
    {
        auto nested = Input::fromAttrs(splitAttrs(input.attrs).first);
        return nested.isRelative();
    }

    std::optional<std::string> getFingerprint(ref<Store> store, const Input & input) const override
    {
        auto nested = Input::fromAttrs(splitAttrs(input.attrs).first);
        auto f = nested.getFingerprint(store);
        return f ? std::optional<std::string>(*f + getEnv("NALE_LAKE2NIX").value()) : std::nullopt;
    }

    nix::StorePath mkFlakeFiles(ref<Store> store, const Input & input, InputAccessor & acc) const
    {
        auto manifest = acc.pathExists(CanonPath("/lake-manifest.json")) ? acc.readFile(CanonPath("/lake-manifest.json")) : "";
        auto lakefile = acc.readFile(CanonPath("/lakefile.lean"));
        auto leanVersion = maybeGetStrAttr(input.attrs, "leanVersion").value_or(chomp(acc.readFile(CanonPath("/lean-toolchain"))));
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
                depInputs += (format("  inputs.%1%.url = nale+%2%/%3%?leanVersion=%4%;\n  inputs.%1%.inputs.lean.follows = \"lean\";\n") %
                    name % url % rev % leanVersion).str();
                deps += (format("inputs.%1% ") % name).str();
            }
        }
        auto flakeContents = format(R"({
  inputs.lean.url = github:%1%;
  inputs.lake2nix.url = %2%;
%3%
  outputs = inputs: inputs.lake2nix.lib.lakeRepo2flake { src = ./.; leanPkgs = inputs.lean.packages; depFlakes = [ %4% ]; };
})") % leanVersion % getEnv("NALE_LAKE2NIX").value() % depInputs % deps;
        writeFile(tmpDir + "/flake.nix", flakeContents.str());
        // creating new EvalState segfaults?
        //auto state = std::shared_ptr<EvalState>(new EvalState({}, store));
        //nix::flake::lockFlake(globals.state, parseFlakeRef(".", tmpDir), {}).lockFile.write(tmpDir + "/flake.lock");
        runProgram(getEnv("NALE_NIX_SELF").value_or("nix"), false, {"-v", "flake", "lock", tmpDir});

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
        auto [nested, ours] = splitAttrs(input.attrs);
        auto input2 = Input::fromAttrs(std::move(nested));
        auto [acc, input3] = input2.getAccessor(store);
        auto flakeFiles = mkFlakeFiles(store, input, *acc);
        input3.attrs = mergeAttrs(input3.attrs, ours);
        return {make_ref<OverlayAccessor>(makeStorePathAccessor(store, flakeFiles), acc), input3};
    }
};

static auto rNaleInputScheme = OnStartup([] { registerInputScheme(std::make_unique<NaleInputScheme>()); });

}
