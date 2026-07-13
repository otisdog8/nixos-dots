# Amazing Marvin - Task management and productivity app

(import ../../../lib/apps.nix).mkApp (
  {
    config,
    lib,
    pkgs,
    ...
  }:
  {
    imports = [
      ../../../lib/features/chromium.nix
      ../../../lib/features/gui.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/network.nix
      ../../../lib/features/audio.nix
      ../../../lib/features/xdg-desktop.nix
    ];

    config.app = {
      name = "amazing-marvin";
      package = pkgs.otisdog8.amazing-marvin;
      packageName = "amazing-marvin";

      # Marvin uses .config/Marvin (profile == persist root). chromium.nix supplies
      # the whole storage layout; no per-app cache list needed.
      defaultBackend = "nixpak";
      chromium.basePath = ".config/Marvin";
    };
  }
)
