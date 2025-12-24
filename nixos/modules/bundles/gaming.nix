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
  ];

  options.modules.bundles.gaming = {
    enable = lib.mkEnableOption "gaming applications bundle";

    enableSandboxing = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable sandboxing for all gaming apps in the bundle";
    };

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
  };

  config = lib.mkIf cfg.enable {
    modules.apps = {
      steam = {
        inherit (cfg.steam) enable;
        sandbox.enable = lib.mkDefault cfg.enableSandboxing;
      };

      prismlauncher = {
        inherit (cfg.prismlauncher) enable;
        sandbox.enable = lib.mkDefault cfg.enableSandboxing;
      };

      lunar-client = {
        inherit (cfg.lunar-client) enable;
        sandbox.enable = lib.mkDefault cfg.enableSandboxing;
      };

      tetrio-desktop = {
        inherit (cfg.tetrio-desktop) enable;
        sandbox.enable = lib.mkDefault cfg.enableSandboxing;
      };

      slipstream = {
        inherit (cfg.slipstream) enable;
        sandbox.enable = lib.mkDefault cfg.enableSandboxing;
      };

      r2modman = {
        inherit (cfg.r2modman) enable;
        sandbox.enable = lib.mkDefault cfg.enableSandboxing;
      };
    };
  };
}
