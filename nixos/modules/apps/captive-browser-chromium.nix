# Dedicated, ephemeral Chromium instance for programs.captive-browser.
#
# The systemd sandbox backend cannot pass arguments into a cold-launched service:
# its launcher starts a static unit whose ExecStart is fixed at build time.  Keep
# that boundary intact by making the captive-portal command line part of this
# instance's package instead of trying to smuggle caller-controlled arguments into
# the privileged launcher.

(import ../../../lib/apps.nix).mkApp (
  {
    lib,
    pkgs,
    ...
  }:
  let
    browserSettings = import ../../../lib/browser-settings.nix { inherit lib; };
    # ungoogled-chromium's compiled-in policy path (lib/browser-settings.nix).
    policyRoot = "/etc/chromium/policies";
  in
  {
    imports = [
      ../../../lib/features/browser.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/xdg-desktop.nix
      ../../../lib/features/tmpfs-homedir.nix
    ];

    config.app = {
      name = "captive-browser-chromium";
      packageName = "chromium-captive";
      package = pkgs.writeShellScriptBin "chromium-captive" ''
        exec ${pkgs.ungoogled-chromium}/bin/chromium \
          --ozone-platform=wayland \
          --enable-features=WebRtcPipeWireCapturer \
          --user-data-dir="''${XDG_DATA_HOME:-$HOME/.local/share}/chromium-captive" \
          --proxy-server="socks5://localhost:1666" \
          --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE localhost" \
          --no-first-run \
          --new-window \
          --incognito \
          --no-default-browser-check \
          http://cache.nixos.org/
      '';

      # A separate uid and tmpfs home isolate portal content from both the normal
      # browser profile and the human user's account. Nothing survives a reboot.
      defaultBackend = "systemd";
      storage = lib.mkForce [ ];

      # Baseline policies only (no telemetry, DoH off so name resolution stays with
      # the portal's SOCKS proxy, no password saving): no extensions, search engine
      # or package changes — the command line above stays as it is.
      capabilities.binds.ro = browserSettings.chromiumBinds {
        appName = "captive-browser-chromium";
        inherit policyRoot;
      };

      customOptions =
        _:
        browserSettings.mkOptions {
          appName = "captive-browser-chromium";
          family = "chromium";
          searchEngine = null;
          withHardwareVideoDecoding = false;
        };

      customConfig =
        { lib, ... }@args:
        lib.mkMerge [
          {
            modules.apps.captive-browser-chromium.sandbox.dedicatedUser = true;
            users.users."app-captive-browser-chromium".extraGroups = [
              "video"
              "audio"
            ];
          }
          (browserSettings.chromiumConfig {
            appName = "captive-browser-chromium";
            inherit policyRoot;
            defaultExtensions = { };
          } args)
        ];
    };
  }
)
