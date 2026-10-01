# Brave web browser

(import ../../../lib/apps.nix).mkApp (
  {
    config,
    lib,
    pkgs,
    ...
  }:
  let
    browserSettings = import ../../../lib/browser-settings.nix { inherit lib; };
    # Native Wayland (a dedicated uid can't auth to XWayland), the PipeWire screen
    # capturer, VA-API and no first-run page (browserSettings.chromiumPackage).
    # Brave's own wrapper passes VA-API features in an --enable-features that ours
    # (the last one, which is the one Chromium keeps) replaces, so they're repeated
    # here via hardwareVideoDecoding.
    mkPackage =
      args:
      browserSettings.chromiumPackage (
        {
          inherit pkgs;
          name = "brave-wayland";
          base = pkgs.brave;
          bin = "brave";
        }
        // args
      );
    policyRoot = "/etc/brave/policies";
  in
  {
    imports = [
      ../../../lib/features/chromium.nix
      ../../../lib/features/browser.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/xdg-desktop.nix
    ];

    config.app = {
      name = "brave";
      # Default build; customConfig rebuilds it from modules.apps.brave.browser.
      package = mkPackage { };
      packageName = "brave";
      desktopFileName = "brave-browser.desktop";

      # Brave keeps its profile under .config/BraveSoftware/Brave-Browser, with the
      # real per-profile caches under Default/. profiles=["Default"] makes chromium.nix
      # carve them (Cache/Code Cache/GPUCache/Dawn*/Service Worker/CacheStorage) to
      # /cache.
      chromium.basePath = ".config/BraveSoftware/Brave-Browser";
      chromium.profiles = [ "Default" ];

      # Dedicated-uid + persistent: logins/passwords/history run as app-brave, hidden
      # from a compromised jrt, kept across reboots via the stash (like zen). chromium
      # profile persisted, caches carved to /cache (chromium.nix).
      defaultBackend = "systemd";

      capabilities.binds.ro = browserSettings.chromiumBinds {
        appName = "brave";
        inherit policyRoot;
      };

      # modules.apps.brave.browser.*: policies, extensions (Vimium by default), … —
      # see lib/browser-settings.nix. Brave Search is already a private default, so
      # the search engine is left alone.
      customOptions =
        _:
        browserSettings.mkOptions {
          appName = "brave";
          family = "chromium";
          searchEngine = null;
        };

      customConfig =
        { config, lib, ... }@args:
        lib.mkMerge [
          {
            modules.apps.brave.sandbox.dedicatedUser = true;
            # Downloads land in jrt's ~/Downloads/brave (host-visible, persisted)
            # instead of the app's 0700 home, which jrt can't open.
            modules.apps.brave.sandbox.sharedDownloads = true;
            users.users."app-brave".extraGroups = [
              "video"
              "audio"
            ];
          }
          (browserSettings.chromiumConfig {
            appName = "brave";
            inherit policyRoot mkPackage;
            # Vimium only: Brave Shields already block ads and trackers.
            defaultExtensions = browserSettings.knownExtensions.vimium.chromium;
            # Brave's own telemetry (P3A, stats ping, Web Discovery) and Rewards,
            # its Brave Ads programme.
            extraManaged = {
              BraveP3AEnabled = false;
              BraveStatsPingEnabled = false;
              BraveWebDiscoveryEnabled = false;
              BraveRewardsDisabled = true;
            };
          } args)
        ];
    };
  }
)
