# TETR.IO Desktop - Online stacker game

(import ../../../lib/apps.nix).mkApp (
  { config, lib, pkgs, ... }: {
    imports = [
      ../../../lib/features/chromium.nix
      ../../../lib/features/gui.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/network.nix
      ../../../lib/features/xdg-desktop.nix
    ];

    config.app = {
      name = "tetrio-desktop";
      package = pkgs.tetrio-desktop;
      packageName = "tetrio";

      # TETR.IO uses standard .config/tetrio-desktop location
      # chromium.basePath defaults to ".config/${name}" which is correct
    };
  }
)
