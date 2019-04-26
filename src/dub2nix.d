#!/usr/bin/env dub
/+ dub.sdl:
    name "dub2nix"
    stringImportPaths "."
    dependency "vibe-d:data" version="*"
+/
import vibe.data.json, std.string;

// enum mkDubNix = import("./mkDub.nix");

struct DubSelections {
    int fileVersion;
    string[string] versions;
}

struct DubRepo {
    string owner;
    string kind;
    string project;
}

private string packageRegistry = "http://code.dlang.org/packages/";

private auto download(string url) @trusted {
version(none) {
    // This works, but causes "leaking eventcore driver" warnings at shutdown
    import vibe.http.client : requestHTTP;
    scope res = requestHTTP();
    return res.readJson();
} else {
    import std.net.curl: get, HTTP;
    auto http = HTTP();
    // Using deflate saves A LOT of traffic, ~40x
    http.addRequestHeader("accept-encoding", "deflate");
    http.addRequestHeader("accept", "application/json");
    const data = get(url, http);
    // Only accepting application/json, so anything else must be compressed
    if (data[0] != '{') {
        import std.zlib : uncompress;
        return parseJsonString(cast(string)uncompress(data));
    } else {
        // parseJsonString takes immutable string, so need the .idup here
        return parseJsonString(data.idup);
    }
}
}

/// Query Dub registry for the repository information of a package
auto findRepo(string pname) @safe {
    const url = packageRegistry ~ pname ~ ".json";
    const json = download(url);
    return deserializeJson!DubRepo(json["repository"]);
}

struct NixPrefetchGit {
    @optional string type;          /// set to "git", like Go deps.nix
    string url;                     /// URL of GIT repository
    string rev;                     /// sha1 or tag
    string sha256;                  /// calculated by from nix-prefetch-git
    @optional bool fetchSubmodules; /// optional; defaults to true
    @optional string date;          /// ignored; fetchgit doesn't actually want this
}

/// Invoke nix-prefetch-git and return the parsed JSON
auto nixPrefetchGit(string url, string rev) @safe {
    import std.process : executeShell;
    return deserializeJson!NixPrefetchGit(
        executeShell("nix-prefetch-git --quiet " ~ url ~ " " ~ rev).output
    );
}

struct DubDep {
    NixPrefetchGit fetch;           /// like Go deps.nix
}

/// Fetch the repo information for package `pname` and version `ver`
auto prefetch(string pname, string ver) @safe {
    const repo = findRepo(pname);
    assert(repo.kind == "github");
    const url = "https://" ~ repo.kind ~ ".com/" ~ repo.owner ~ '/' ~ repo.project ~ ".git";
    const tag = "v" ~ ver;
    auto set = nixPrefetchGit(url, tag);
    // Overwrite the sha1 ref with the tag instead, so we have the version info as well
    set.rev = tag;
    set.type = "git";
    return DubDep(set);
}

/// Convert D string to Nix string literal
auto toNixString(in string s, int indent = 0) pure @safe {
    if (s is null) {
        return "null";
    } else if (s.indexOfAny("\"\n") >= 0)
        return "''\n" ~ s ~ "''";
    else
        return '"' ~ s ~ '"';
}

unittest {
    static assert(toNixString(null) == "null");
    static assert(toNixString("hello") == `"hello"`);
    static assert(toNixString("with\nnewline") == "''\nwith\nnewline''");
    static assert(toNixString(`with "quotes"`) == "''\nwith \"quotes\"''");
}

/// Convert D bool to Nix boolean literal
auto toNixString(bool b, int indent = 0) pure @safe {
    return b ? "true" : "false";
}

unittest {
    static assert(toNixString(true) == "true");
    static assert(toNixString(false) == "false");
}

private enum INDENT = "                                                              ";

/// Convert D struct to Nix set
auto toNixString(T)(in T pod, int indent = 0) pure @safe if (is(T == struct)) {
    string prefix = INDENT[0..indent * 2 + 2];
    string set = "{\n";
    foreach(i, ref key; pod.tupleof) {
        const id = __traits(identifier, pod.tupleof[i]);
        set ~= prefix ~ id ~ " = " ~ toNixString(key, indent + 1) ~ ";\n";
    }
    return set ~ INDENT[0..indent * 2] ~ "}";
}

unittest {
    struct TestStruct { bool b; }
    static assert(toNixString(TestStruct.init) == "{\n  b = false;\n}");
    static assert(toNixString(TestStruct.init, 1) == "{\n    b = false;\n  }");
}

/// Convert D AArray to Nix set
auto toNixString(T)(in T[string] aa, int indent = 0) pure @safe {
    string prefix = INDENT[0..indent * 2 + 2];
    string set = "{\n";
    foreach(id, ref key; aa) {
        set ~= prefix ~ id ~ " = " ~ toNixString(key, indent + 1) ~ ";\n";
    }
    return set ~ INDENT[0..indent * 2] ~ "}";
}

unittest {
    static assert(toNixString(["s": "x"]) == "{\n  s = \"x\";\n}");
    static assert(toNixString(["s": ["x": true]]) == "{\n  s = {\n    x = true;\n  };\n}");
}

/// Convert D array/range to Nix list
import std.range : isForwardRange;
auto toNixString(R)(in R range, int indent = 0) pure @safe if (isForwardRange!R && !is(R : string)) {
    string list = "[ ";
    foreach(const ref item; range) {
        list ~= toNixString(item, indent) ~ " ";
    }
    return list ~ "]";
}

unittest {
    static assert(toNixString(["a"]) == `[ "a" ]`);
}

/// Create Nix expression for all dependencies in the selections JSON
auto createNixDeps(string selectionsJson) {
    import std.parallelism : taskPool;
    import std.array : byPair, array;
    import std.stdio : writeln;

    const selections = deserializeJson!DubSelections(selectionsJson);
    assert(selections.fileVersion == 1);

    static auto progress(Tuple)(in Tuple pair) {
        debug writeln("# Fetching ", pair.key);
        return prefetch(pair.key, pair.value);
    }

    // Fetch all dependency information in parallel
    debug scope(success) writeln("# Done.");
    return "# This file was generated by https://github.com/lionello/dub2nix v0.1.0\n"
        ~ toNixString(taskPool.amap!progress(selections.versions.byPair.array));
}

unittest {
    enum json = import("./dub.selections.json");
    enum fixture = import("./dub.selections.nix");
    assert(createNixDeps(json) == fixture);
}

// No "main" when we're running with unittests
version(unittest) {} else {

int main(string[] args) {
    import std.stdio : writeln;
    import std.file : readText, write;
    import std.getopt: getopt, defaultGetoptPrinter;

    string input = "./dub.selections.json", deps = "./dub.selections.nix";
    auto result = getopt(args,
        "input|i|in", "Path of selections JSON; defaults to " ~ input, &input,
        // "output|o|out", "Output Nix file for Dub project; defaults to " ~ output, &output,
        "registry|r", "URL to Dub package registry; default " ~ packageRegistry, &packageRegistry,
        "deps-file|d", "Output Nix file with dependencies; defaults to " ~ deps, &deps);

    if (result.helpWanted || args.length != 2 || args[1] != "save") {
        defaultGetoptPrinter(`Usage: dub2nix [OPTIONS] COMMAND

Create Nix derivations for Dub package dependencies.

Commands:
  save         Write Nix files for Dub project

Options:`, result.options);
        return 0;
    }

    try {
        const nix = createNixDeps(readText(input));
        if (deps == "-") {
            writeln(nix);
        } else {
            write(deps, nix.representation);
        }
        return 0;
    } catch (Exception e) {
        debug {
            // Only dump callstack in debug builds
            writeln(e.toString());
        } else {
            writeln(e.message);
        }
        return 1;
    }
}

}//!unittest
