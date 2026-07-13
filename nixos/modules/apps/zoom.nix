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

      # Drive Qt onto XCB/XWayland (not native Wayland): zoom's bundled Qt6 segfaulted a
      # child on native Wayland, and a dedicated uid can only reach XWayland via the
      # x11Forward grant (customConfig below). QT_QPA_PLATFORM=xcb + x11Forward is the
      # working combo; the socket/auth for it is set up by the launcher.
      nixpakModules = [
        (
          { ... }:
          {
            bubblewrap.env.QT_QPA_PLATFORM = "xcb";
          }
        )
      ];

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.zoom.sandbox.dedicatedUser = true;
          modules.apps.zoom.sandbox.x11Forward = true;
          users.users."app-zoom".extraGroups = [
            "video"
            "audio"
          ];
        };
    };
  }
)
