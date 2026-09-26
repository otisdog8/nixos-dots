# Chromium web browser

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
    mkPackage =
      args:
      browserSettings.chromiumPackage (
        {
          inherit pkgs;
          name = "chromium-wayland";
          base = pkgs.chromium;
          bin = "chromium";
        }
        // args
      );
    policyRoot = "/etc/chromium/policies";
  in
  {
    imports = [
      ../../../lib/features/chromium.nix
      ../../../lib/features/browser.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/xdg-desktop.nix
      ../../../lib/features/onepassword-chromium.nix
    ];

    config.app = {
      name = "chromium";
      # Default build; customConfig rebuilds it from modules.apps.chromium.browser.
      package = mkPackage { };
      packageName = "chromium";
      desktopFileName = "chromium-browser.desktop";

      # basePath defaults to .config/chromium (correct). Caches live under Default/,
      # so profiles=["Default"] carves them (Cache/Code Cache/GPUCache/Dawn*/Service
      # Worker/CacheStorage) to /cache.
      chromium.profiles = [ "Default" ];

      # Dedicated-uid + persistent, mirroring brave/zen: profile hidden from jrt and
      # kept across reboots; caches carved to /cache by chromium.nix.
      defaultBackend = "systemd";

      # This app's own policy files (host /etc, written by customConfig), bound
      # read-only at the same path in every implementation — see
      # lib/browser-settings.nix.
      capabilities.binds.ro = browserSettings.chromiumBinds {
        appName = "chromium";
        inherit policyRoot;
      };

      # modules.apps.chromium.browser.*: policies, extensions (uBlock Origin Lite and
      # Vimium by default), search engine, … — see lib/browser-settings.nix.
      customOptions =
        _:
        browserSettings.mkOptions {
          appName = "chromium";
          family = "chromium";
        };

      customConfig =
        { config, lib, ... }@args:
        lib.mkMerge [
          {
            modules.apps.chromium.sandbox.dedicatedUser = true;
            # Downloads land in jrt's ~/Downloads/chromium (host-visible, persisted)
            # instead of the app's 0700 home, which jrt can't open.
            modules.apps.chromium.sandbox.sharedDownloads = true;
            users.users."app-chromium".extraGroups = [
              "video"
              "audio"
            ];
          }
          (browserSettings.chromiumConfig {
            appName = "chromium";
            inherit policyRoot mkPackage;
          } args)
        ];
    };
  }
)
