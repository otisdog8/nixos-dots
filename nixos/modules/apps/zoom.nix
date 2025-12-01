# Zoom video conferencing

(import ../../../lib/apps.nix).mkApp (
  { config, lib, pkgs, ... }: {
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

      persistence.user.persist = [
        ".zoom"
      ];

      persistence.user.persistFiles = [
        ".config/zoom.conf"
        ".config/zoomus.conf"
      ];
    };
  }
)
