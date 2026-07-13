# Chromium-based application feature (Chrome, Brave, Electron apps, etc.)
#
# Chromium/Electron apps all share the same on-disk shape: a profile directory
# (basePath) full of real state (Cookies, Local Storage, session, etc.) with a
# well-known set of regenerable cache subdirectories mixed in. This feature
# encodes that shape ONCE so every chromium app gets:
#   - the profile on the backed-up /persist tier, and
#   - each cache subdir carved out to the disposable /cache tier (cross-tier
#     children of the persist parent — no same-tier nesting, no desync).
#
# It emits BOTH layouts so it works before and after conversion:
#   - legacy backend → persistence.user.* (impermanence), unchanged.
#   - v2 backend     → app.storage. Inert for legacy apps (storage.nix output is
#     only wired in for non-legacy backends), so a chromium app converts by simply
#     setting `defaultBackend = "nixpak"` — no per-app cache list to repeat.
{ config, lib, ... }:
let
  cfg = config.app.chromium;
  base = cfg.basePath;

  topCaches = map (c: {
    path = "${base}/${c}";
    tier = "cache";
  }) cfg.cacheDirs;

  profileCaches = lib.concatMap (
    p:
    map (c: {
      path = "${base}/${p}/${c}";
      tier = "cache";
    }) cfg.profileCacheDirs
  ) cfg.profiles;

  # Caches that live OUTSIDE basePath, relative to persistRoot (e.g. vesktop's
  # Crashpad sits next to sessionData, not inside it).
  extraCaches = map (c: {
    path = "${cfg.persistRoot}/${c}";
    tier = "cache";
  }) cfg.extraCacheDirs;
in
{
  imports = [
    ./gui.nix
    ../app-spec.nix
  ];

  options.app.chromium = {
    basePath = lib.mkOption {
      type = lib.types.str;
      default = ".config/${config.app.name}";
      description = "Base path for the Chromium/Electron PROFILE (where the caches live).";
    };

    persistRoot = lib.mkOption {
      type = lib.types.str;
      default = config.app.chromium.basePath;
      description = ''
        Top directory to persist. Defaults to basePath. Set it to a PARENT when the
        Electron profile is a subdirectory (e.g. vesktop keeps its profile at
        .config/vesktop/sessionData but real state — Vencord settings/themes — sits
        in the parent .config/vesktop), so that sibling state isn't dropped.
      '';
    };

    extraCacheDirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Extra cache subdirectories relative to persistRoot, for caches that live
        OUTSIDE basePath (e.g. vesktop's Crashpad, a sibling of sessionData).
      '';
    };

    cacheDirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "Cache"
        "Code Cache"
        "GPUCache"
        "DawnCache"
        "DawnGraphiteCache"
        "DawnWebGPUCache"
        "GrShaderCache"
        "ShaderCache"
        "blob_storage"
        "Crashpad"
        "component_crx_cache"
        "Shared Dictionary/cache"
      ];
      description = ''
        Top-level Chromium/Electron cache subdirectories (relative to basePath)
        routed to the disposable /cache tier in the v2 backend. Listing one that a
        given app never creates is harmless — it just prepares an empty cache dir.
      '';
    };

    profiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Browser profile directories (e.g. [ "Default" "Profile 1" ]). Full browsers
        keep their caches UNDER each profile; single-profile Electron apps (most
        packaged apps) keep them at basePath, so leave this empty for those.
      '';
    };

    profileCacheDirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "Cache"
        "Code Cache"
        "GPUCache"
        "DawnCache"
        "DawnGraphiteCache"
        "DawnWebGPUCache"
        "GrShaderCache"
        "Service Worker/CacheStorage"
        "Service Worker/ScriptCache"
      ];
      description = "Per-profile cache subdirectories (under each entry in `profiles`) → /cache.";
    };
  };

  config.app = {
    # ── Legacy backend (impermanence) — unchanged for back-compat.
    # (persistRoot defaults to basePath, so this is identical for existing apps.) ──
    persistence.user.persist = [ cfg.persistRoot ];
    persistence.user.cache = [
      "${base}/Cache"
      "${base}/GPUCache"
      "${base}/Code Cache"
      "${base}/DawnCache"
    ];

    # ── v2 backend — unified storage: persistRoot on /persist, caches on /cache.
    # Inert for legacy apps; used the moment an app sets a non-legacy backend.
    storage = [
      {
        path = cfg.persistRoot;
        tier = "persist";
      }
    ]
    ++ topCaches
    ++ profileCaches
    ++ extraCaches;
  };
}
