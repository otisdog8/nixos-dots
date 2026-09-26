# Ungoogled Chromium - ephemeral browser with tmpfs homedir

(import ../../../lib/apps.nix).mkApp (
  {
    config,
    lib,
    pkgs,
    ...
  }:
  let
    browserSettings = import ../../../lib/browser-settings.nix { inherit lib; };
    # Native Wayland (hint alone falls back to XWayland, which a dedicated uid can't
    # auth to), the PipeWire screen capturer (portal ScreenCast), VA-API and no
    # first-run page (browserSettings.chromiumPackage).
    mkPackage =
      args:
      browserSettings.chromiumPackage (
        {
          inherit pkgs;
          name = "ungoogled-chromium-wayland";
          base = pkgs.ungoogled-chromium;
          bin = "chromium";
        }
        // args
      );
    # Same compiled-in policy path as Chromium; the per-app file name keeps the two
    # apart (lib/browser-settings.nix).
    policyRoot = "/etc/chromium/policies";
  in
  {
    imports = [
      ../../../lib/features/chromium.nix
      ../../../lib/features/browser.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/xdg-desktop.nix
    ];

    config.app = {
      name = "ungoogled-chromium";
      # Default build; customConfig rebuilds it from
      # modules.apps.ungoogled-chromium.browser.
      package = mkPackage { };
      packageName = "chromium";
      desktopFileName = "chromium-browser.desktop";

      # Dedicated-uid + ephemeral: runs as app-ungoogled-chromium (data hidden from
      # jrt). The app's $HOME isn't bound into the sandbox — bwrap creates it on its
      # own tmpfs root, so the profile is discarded on every exit. Clear
      # chromium.nix's persist storage so no stash is created/backed-up.
      defaultBackend = "systemd";
      storage = lib.mkForce [ ];

      capabilities.binds.ro = browserSettings.chromiumBinds {
        appName = "ungoogled-chromium";
        inherit policyRoot;
      };

      # modules.apps.ungoogled-chromium.browser.* — see lib/browser-settings.nix.
      customOptions =
        _:
        browserSettings.mkOptions {
          appName = "ungoogled-chromium";
          family = "chromium";
        };

      customConfig =
        { config, lib, ... }@args:
        lib.mkMerge [
          {
            modules.apps.ungoogled-chromium.sandbox.dedicatedUser = true;
            # Downloads land in jrt's ~/Downloads/ungoogled-chromium (host-visible).
            modules.apps.ungoogled-chromium.sandbox.sharedDownloads = true;
            users.users."app-ungoogled-chromium".extraGroups = [
              "video"
              "audio"
            ];
          }
          (browserSettings.chromiumConfig {
            appName = "ungoogled-chromium";
            inherit policyRoot mkPackage;
            # No default extensions (not even uBlock Origin Lite / Vimium, which the
            # other browsers get): force-installing from the Chrome Web Store would
            # make this browser fetch from Google on every (ephemeral) start. Add
            # some through modules.apps.ungoogled-chromium.browser.extensions, or
            # an unpacked one through …browser.unpackedExtensions.
            defaultExtensions = { };
          } args)
        ];
    };
  }
)
