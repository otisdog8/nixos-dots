# Gaming applications bundle
{ config, lib, ... }:
let
  cfg = config.modules.bundles.gaming;
in
{
  imports = [
    ../apps/steam.nix
    ../apps/prismlauncher.nix
    ../apps/lunar-client.nix
    ../apps/tetrio-desktop.nix
    ../apps/slipstream.nix
    ../apps/r2modman.nix
    ../apps/wine.nix
  ];

  options.modules.bundles.gaming = {
    enable = lib.mkEnableOption "gaming applications bundle";

    steam.enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      description = "Enable Steam";
    };

    prismlauncher.enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      description = "Enable PrismLauncher (Minecraft)";
    };

    lunar-client.enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      description = "Enable Lunar Client (Minecraft)";
    };

    tetrio-desktop.enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      description = "Enable TETR.IO Desktop";
    };

    slipstream.enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      description = "Enable Slipstream (FTL mod manager)";
    };

    r2modman.enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      description = "Enable r2modman (game mod manager)";
    };

    wine.enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      description = "Enable Wine (run Windows games and applications)";
    };
  };

  config = lib.mkIf cfg.enable {
    # Steam and its mod tools share files (game folders, r2modman's profiles and
    # its launch wrapper, Steam's launch options): as containers, one shared
    # container (the user service sbx-group-games, lib/backends/nixpak-group.nix;
    # it stops a minute after the last of them exits), each started in its home
    # there (none takes $PWD); in VM mode (sandbox.mode = "vm", or their "(vm)"
    # variants), one group VM with one guest home. Sized as Steam's own VM
    # (apps/steam.nix).
    modules.sandbox.groups.games = lib.mkIf cfg.steam.enable {
      apps = [
        "steam"
      ]
      ++ lib.optional cfg.r2modman.enable "r2modman"
      ++ lib.optional cfg.slipstream.enable "slipstream";
      persistent = false;
      vm = {
        memory = 32768;
        vcpus = 12;
        gpuMemoryMiB = 24576;
        gpuMemoryProcessPercent = 90;
        tuning = "game";
      };
    };

    modules.apps = {
      steam = {
        inherit (cfg.steam) enable;
      };

      prismlauncher = {
        inherit (cfg.prismlauncher) enable;
      };

      lunar-client = {
        inherit (cfg.lunar-client) enable;
      };

      tetrio-desktop = {
        inherit (cfg.tetrio-desktop) enable;
      };

      slipstream = {
        inherit (cfg.slipstream) enable;
      };

      r2modman = {
        inherit (cfg.r2modman) enable;
      };

      # Wine runs unsandboxed (backend "none", see apps/wine.nix).
      wine = {
        inherit (cfg.wine) enable;
      };
    };
  };
}
