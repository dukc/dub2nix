{ pkgs ? import <nixpkgs> {},
  stdenv ? pkgs.stdenv,
  lib ? pkgs.lib,
  rdmd ? pkgs.rdmd,
  dcompiler ? pkgs.dmd,
  dub ? pkgs.dub }:

with stdenv;
let
  # Filter function to remove the .dub package folder from src
  filterDub = name: type: let baseName = baseNameOf (toString name); in ! (
    type == "directory" && baseName == ".dub"
  );

  # Convert a GIT rev string (tag) to a simple semver version
  rev-to-version = builtins.replaceStrings ["v" "refs/tags/v"] ["" ""];

  dep2src = dubDep: pkgs.fetchgit { inherit (dubDep.fetch) url rev sha256 fetchSubmodules; };

  # Fetch a dependency (source only for now)
  fromDub = dubDep: mkDerivation rec {
    name = "${src.name}-${version}";
    version = rev-to-version dubDep.fetch.rev;
    nativeBuildInputs = [ dcompiler rdmd dub ];
    src = dep2src dubDep;

    buildPhase = ''
      runHook preBuild
      export HOME=$PWD
      dub build -b=release
      runHook postBuild
    '';

    # outputs = [ "lib" ];

    # installPhase = ''
    #   runHook preInstall
    #   mkdir -p $out/bin
    #   runHook postInstall
    # '';
  };

  # Adds a local package directory (e.g. a git repository) to Dub
  dub-add-local = dubDep: "dub add-local ${(fromDub dubDep).src.outPath} ${rev-to-version dubDep.fetch.rev}";

  # The target output of the Dub package
  targetOf = package: "${package.targetPath or "."}/${package.targetName or package.name}";

  # Remove reference to build tools and library sources
  disallowedReferences = deps: [ dcompiler rdmd dub ] ++ builtins.map dep2src deps;

  removeExpr = refs: ''remove-references-to ${lib.concatMapStrings (ref: " -t ${ref}") refs}'';

in {
  inherit fromDub;

  mkDubDerivation = lib.makeOverridable ({
    src,
    nativeBuildInputs ? [],
    dubJSON ? src + "/dub.json",
    selections ? src + "/dub.selections.nix",
    deps ? import selections,
    passthru ? {},
    package ? lib.importJSON dubJSON,
    ...
  } @ attrs: stdenv.mkDerivation ((removeAttrs attrs ["package" "deps" "selections" "dubJSON"]) // {

    pname = package.name;

    nativeBuildInputs = [ dcompiler rdmd dub pkgs.removeReferencesTo ] ++ nativeBuildInputs;
    disallowedReferences = disallowedReferences deps;

    passthru = passthru // {
      inherit dub dcompiler rdmd pkgs;
    };

    src = lib.cleanSourceWith {
      filter = filterDub;
      src = lib.cleanSource src;
    };

    preFixup = ''
      find $out/bin -type f -exec ${removeExpr (disallowedReferences deps)} '{}' + || true
    '';

    buildPhase = ''
      runHook preBuild

      export HOME=$PWD
      ${lib.concatMapStringsSep "\n" dub-add-local deps}
      dub build -b release --combined --skip-registry=all

      runHook postBuild
    '';

    checkPhase = ''
      runHook preCheck

      export HOME=$PWD
      ${lib.concatMapStringsSep "\n" dub-add-local deps}
      dub test --combined --skip-registry=all

      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin
      cp -r "${targetOf package}" $out/bin

      runHook postInstall
    '';

    meta = lib.optionalAttrs (package ? description) {
      description = package.description;
    } // attrs.meta or {};
  } // lib.optionalAttrs (!(attrs ? version)) {
    # Use name from dub.json, unless pname and version are specified
    name = package.name;
  }));
}
