# Lunar Client - Minecraft PvP client

(import ../../../lib/apps.nix).mkApp (
  { config, lib, pkgs, ... }: {
    imports = [
      ../../../lib/features/gui.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/network.nix
      ../../../lib/features/audio.nix
      ../../../lib/features/xdg-desktop.nix
    ];

    config.app = {
      name = "lunar-client";
      package = pkgs.lunar-client;
      packageName = "lunarclient";

      # Main config and data (settings, mods, resourcepacks)
      persistence.user.persist = [
        ".lunarclient"
        ".local/share/lunarclient"
      ];

      # Large files (offline files, JRE runtime)
      persistence.user.large = [
        ".lunarclient/offline"
        ".lunarclient/jre"
      ];

      # Cache directory
      persistence.user.cache = [
        ".config/lunarclient"
      ];
    };
  }
)
