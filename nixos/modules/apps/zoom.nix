# Zoom video conferencing — dedicated-uid sandbox, persistent config

(import ../../../lib/apps.nix).mkApp (
  {
    config,
    lib,
    pkgs,
    ...
  }:
  {
    imports = [
      ../../../lib/features/gui.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/network.nix
      ../../../lib/features/audio.nix
      ../../../lib/features/camera.nix
      ../../../lib/features/screen-capture.nix
      ../../../lib/features/xdg-desktop.nix
      ../../../lib/features/system-tray.nix
    ];

    config.app = {
      name = "zoom";
      package = pkgs.zoom-us;
      packageName = "zoom";

      # Dedicated-uid, persistent: login/settings (.zoom + the two confs) run as
      # app-zoom — hidden from a compromised jrt — and kept across reboots. Screen
      # share rides the PipeWire portal (works cross-uid already).
      defaultBackend = "systemd";
      storage = [
        {
          path = ".zoom";
          tier = "persist";
        }
        {
          path = ".config/zoom.conf";
          tier = "persist";
          type = "file";
        }
        {
          path = ".config/zoomus.conf";
          tier = "persist";
          type = "file";
        }
      ];

      # Force Qt onto native Wayland: XWayland needs a cross-uid X-auth the dedicated
      # uid doesn't have (same reason vesktop forces --ozone-platform=wayland).
      nixpakModules = [
        (
          { ... }:
          {
            bubblewrap.env.QT_QPA_PLATFORM = "wayland";
          }
        )
      ];

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.zoom.sandbox.dedicatedUser = true;
          users.users."app-zoom".extraGroups = [
            "video"
            "audio"
          ];
        };
    };
  }
)
