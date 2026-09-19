{ inputs, ... }:
final: prev: {
  zen-browser = inputs.zen-browser.packages.${final.stdenv.hostPlatform.system}.default;

  # Local change to xdg-desktop-portal, carried as a diff over nixpkgs' own pinned
  # source (currently 1.20.4) rather than a whole-source fork — so we inherit upstream
  # bumps for free and only maintain the delta.
  #
  # allow_other on the document-portal FUSE mount (substituteInPlace one-liner) so a
  # DEDICATED-uid sandbox app (running as app-<name>, not jrt) can read the doc://
  # files jrt's portal exports for it. The daemon still does its own per-app access
  # control in the FUSE handlers (this only lifts the kernel's mounting-uid-only
  # gate); NOT default_permissions, which would re-impose inode-uid checks and defeat
  # it. Requires programs.fuse.userAllowOther (fusermount3 rejects allow_other
  # otherwise — and the portal would then fail to mount at all).
  #
  # DISABLED (kept in-repo): xdg-desktop-portal-fallback.patch — the document-portal
  # fallback-access feature (inode-comparison app_has_file_access_fallback via
  # bwrapinfo.json). Turned off for now: it caused a writable-paths issue and nothing
  # currently depends on it. To re-enable, add it back to `patches` below. Regenerate
  # on a version bump with:
  #   git -C <fork> diff 2c75f6f..18f02f5 -- document-portal/document-portal.c
  #   (base 2c75f6f = upstream v1.20.4; head = otisdog8 fallback-improvements-120).
  #   Needs json-glib, which nixpkgs' portal already links — no buildInput change.
  xdg-desktop-portal = prev.xdg-desktop-portal.overrideAttrs (oldAttrs: {
    postPatch = (oldAttrs.postPatch or "") + ''
      substituteInPlace document-portal/document-portal-fuse.c \
        --replace-fail 'fsname=portal,auto_unmount",' 'fsname=portal,auto_unmount,allow_other",'
    '';
  });

  # nixpkgs pins several Electron apps (vesktop here) to pnpm 10.29.2, which is
  # marked insecure (CVE-2026-48995 + others). Swap the build-time pnpm for the
  # current secure 10.x so we remove the vulnerable package instead of
  # allow-listing it. Temporary until upstream fixes land (nixpkgs#536623).
  pnpm_10_29_2 = final.pnpm_10;

  # nixpkgs removed `sweet` (2af5c1bd4f) because it propagated gtk-engine-murrine,
  # which was dropped as unmaintained GTK 2 tech. But murrine was only needed for
  # the theme's legacy GTK 2 support — the GTK 3/4 theme data we actually use
  # (share/themes/Sweet/…, consumed by theming.nix + the sandbox theme binds) is
  # plain CSS. Carry the last nixpkgs derivation locally, minus the murrine
  # propagation. sweet-nova (Kvantum side) survived upstream and stays from nixpkgs.
  sweet =
    let
      version = "6.0";
      variants = {
        "Sweet-Ambar-Blue-Dark-v40" = "sha256-LufK9MexE6YMuVniyfcNNaPfVLBMHnNmWBBNnGA2nUo=";
        "Sweet-Ambar-Blue-Dark" = "sha256-J0YOADP4FXKYMl/Nn70clD3h7Y5LtlTfWV9VLsWL9yo=";
        "Sweet-Ambar-Blue-v40" = "sha256-HH9oZQ+F1nFhIJyP9d9W2CL+mA0bolq5GiNQtKQgrZk=";
        "Sweet-Ambar-Blue" = "sha256-2dcryd5Zj+Iu3R4jR++uJtyToGNoa1LtTpN1G6+kBRw=";
        "Sweet-Ambar-v40" = "sha256-mpShu1fmBajl/wzlnu9zBWkskMlza5nEVS3u8Sh3b7s=";
        "Sweet-Ambar" = "sha256-wcbJW6MUctGSM8GW1ouLvUCmdcDHQkjTw9h0foRBgTg=";
        "Sweet-Dark-v40" = "sha256-aYPjnOEZMN9mPvnhK3eoCm1ybUxKPqPSoOL+kwsZsG4=";
        "Sweet-Dark" = "sha256-Ej9p7/txrMhGUCyDTAEQHIS/pi92pfLrCV1L4HxWdZk=";
        "Sweet-mars-v40" = "sha256-AKTNa6FHlPr1ZqlK5QYZzXRiPb5Nmzw2lTSNcWAtMAg=";
        "Sweet-mars" = "sha256-bCL/DqiQGiHR24aaPtPyJKAkk8X+DyMxYeYuFJBuK6Y=";
        "Sweet-v40" = "sha256-1kHWoK9r3mRYIkizekVVYyFpWXU78BExKuNUsRB4uv4=";
        "Sweet" = "sha256-WzsquuUreT7b6TA6qGSYqGVrVWlIdQjlIdqWGMNJFpo=";
      };
    in
    prev.stdenvNoCC.mkDerivation {
      pname = "sweet";
      inherit version;

      srcs = prev.lib.mapAttrsToList (
        name: hash:
        prev.fetchurl {
          url = "https://github.com/EliverLara/Sweet/releases/download/v${version}/${name}.tar.xz";
          inherit hash;
        }
      ) variants;

      sourceRoot = ".";

      installPhase = ''
        runHook preInstall
        mkdir -p $out/share/themes/
        cp -r ${prev.lib.concatStringsSep " " (builtins.attrNames variants)} $out/share/themes/
        runHook postInstall
      '';

      meta = {
        description = "Light and dark colorful Gtk3.20+ theme";
        homepage = "https://github.com/EliverLara/Sweet";
        license = prev.lib.licenses.gpl3Plus;
        platforms = prev.lib.platforms.unix;
      };
    };

  # cantarell-fonts 0.311 fails to build on the nixos-* channels (otfautohint
  # errors on uni0424 during variable-font generation with afdko 5.0.1). The
  # nixpkgs-unstable branch has the fixed rebuild; pin from there. A font is
  # leaf data so cross-pinning is safe. Drop once the fix reaches nixos-unstable.
  cantarell-fonts =
    inputs.nixpkgs-unstable.legacyPackages.${final.stdenv.hostPlatform.system}.cantarell-fonts;
}
