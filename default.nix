{ pkgs ? import <nixpkgs> { }
, system ? builtins.currentSystem
,
}:
let
  inherit (pkgs) lib;
  sources = builtins.fromJSON (lib.strings.fileContents ./sources.json);
  mirrors = builtins.fromJSON (lib.strings.fileContents ./mirrors.json);

  # mkBinaryInstall makes a derivation that installs Zig from a binary.
  mkBinaryInstall =
    { url
    , version
    , sha256
    ,
    }:
    let
      tarballName = lib.lists.last (lib.strings.split "/" url);
      srcIsFromZigLang = lib.strings.hasPrefix "https://ziglang.org/" url;
      urlFromMirrors =
        builtins.map
          (mirror: "${mirror}/${tarballName}?source=nix-zig-overlay")
          mirrors;
      urls =
        if srcIsFromZigLang
        then urlFromMirrors ++ [ url ]
        else [ url ];
    in
    pkgs.stdenv.mkDerivation (finalAttrs: {
      inherit version;

      pname = "zig";
      src = pkgs.fetchurl { inherit urls sha256; };
      # dontConfigure = true;
      # dontBuild = true;
      # dontFixup = true;
      preBuild = ''
        export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache";
      '';
      strictDeps = true;

      installPhase = ''
        mkdir -p $out/{doc,bin,lib}
        [ -d docs ] && cp -r docs/* $out/doc
        [ -d doc ] && cp -r doc/* $out/doc
        cp -r lib/* $out/lib
        cp zig $out/bin/zig
      '';
      passthru = import ./passthru.nix {
        inherit (pkgs)
          stdenv
          callPackage
          wrapCCWith
          wrapBintoolsWith
          overrideCC
          ;
        zig = finalAttrs.finalPackage;
      };

      env = {
        # This zig_default_optimize_flag below is meant to avoid CPU feature impurity in
        # Nixpkgs. However, this flagset is "unstable": it is specifically meant to
        # be controlled by the upstream development team - being up to that team
        # exposing or not that flags to the outside (especially the package manager
        # teams).

        # Because of this hurdle, @andrewrk from Zig Software Foundation proposed
        # some solutions for this issue. Hopefully they will be implemented in
        # future releases of Zig. When this happens, this flagset should be
        # revisited accordingly.

        # Below are some useful links describing the discovery process of this 'bug'
        # in Nixpkgs:

        # https://github.com/NixOS/nixpkgs/issues/169461
        # https://github.com/NixOS/nixpkgs/issues/185644
        # https://github.com/NixOS/nixpkgs/pull/197046
        # https://github.com/NixOS/nixpkgs/pull/241741#issuecomment-1624227485
        # https://github.com/ziglang/zig/issues/14281#issuecomment-1624220653
        zig_default_cpu_flag = "-Dcpu=baseline";

        zig_default_optimize_flag =
          if lib.versionAtLeast finalAttrs.version "0.12" then
            "--release=safe"
          else if lib.versionAtLeast finalAttrs.version "0.11" then
            "-Doptimize=ReleaseSafe"
          else
            "-Drelease-safe=true";
      };

      setupHook = ./setup-hook.sh;
    });

  # The packages that are tagged releases
  taggedPackages =
    lib.attrsets.mapAttrs
      (k: v: mkBinaryInstall { inherit (v.${system}) version url sha256; })
      (lib.attrsets.filterAttrs
        (k: v: (builtins.hasAttr system v) && (v.${system}.url != null) && (v.${system}.sha256 != null))
        (builtins.removeAttrs sources [ "master" ]));

  # The master packages
  masterPackages =
    lib.attrsets.mapAttrs'
      (
        k: v:
          lib.attrsets.nameValuePair
            (
              if k == "latest"
              then "master"
              else ("master-" + k)
            )
            (mkBinaryInstall { inherit (v.${system}) version url sha256; })
      )
      (lib.attrsets.filterAttrs
        (k: v: (builtins.hasAttr system v) && (v.${system}.url != null))
        sources.master);

  # This determines the latest /released/ version.
  latest = lib.lists.last (
    builtins.sort
      (x: y: (builtins.compareVersions x y) < 0)
      (builtins.attrNames taggedPackages)
  );
in
# We want the packages but also add a "default" that just points to the
  # latest released version.
taggedPackages // masterPackages // { "default" = taggedPackages.${latest}; }
