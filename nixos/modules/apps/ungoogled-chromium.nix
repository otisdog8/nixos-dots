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
            # Vimium and uBlock Origin Lite, loaded unpacked from the store
            # (lib/chromium-extensions.nix): the Web Store can't work here (see
            # below). Merged with op-broker's; to drop them on a host, mkForce the list.
            modules.apps.ungoogled-chromium.browser.unpackedExtensions =
              let
                ext = import ../../../lib/chromium-extensions.nix { inherit pkgs; };
              in
              [
                "${ext.vimium}"
                "${ext.ublock-origin-lite}"
              ];
            users.users."app-ungoogled-chromium".extraGroups = [
              "video"
              "audio"
            ];
          }
          (browserSettings.chromiumConfig {
            appName = "ungoogled-chromium";
            inherit policyRoot mkPackage;
            # No Web Store force-installs: ungoogled-chromium rewrites Google's
            # domains, so they can't work (and would contact Google on every
            # ephemeral start). Vimium and uBlock Origin Lite come unpacked from
            # the store instead (unpackedExtensions above).
            defaultExtensions = { };
          } args)
        ];
    };
  }
)
