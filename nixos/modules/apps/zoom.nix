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

      # POC XWayland forward test case: previously forced onto native Wayland because a
      # dedicated uid couldn't auth to XWayland — the x11Forward POC removes exactly
      # that barrier (launcher xhost grant + X socket), so drive Qt onto XCB/XWayland
      # through the forward and see whether zoom is happier there (it segfaulted a Qt6
      # child on native Wayland — see the zoom TODO). Flip QT_QPA_PLATFORM back to
      # "wayland" + x11Forward=false to revert.
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
