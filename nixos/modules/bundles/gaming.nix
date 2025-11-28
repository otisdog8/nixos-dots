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
  };

  config = lib.mkIf cfg.enable {
    modules.apps.steam = {
      enable = cfg.steam.enable;
      sandbox.enable = lib.mkDefault cfg.enableSandboxing;
    };

    modules.apps.prismlauncher = {
      enable = cfg.prismlauncher.enable;
      sandbox.enable = lib.mkDefault cfg.enableSandboxing;
    };

    modules.apps.lunar-client = {
      enable = cfg.lunar-client.enable;
      sandbox.enable = lib.mkDefault cfg.enableSandboxing;
    };

    modules.apps.tetrio-desktop = {
      enable = cfg.tetrio-desktop.enable;
      sandbox.enable = lib.mkDefault cfg.enableSandboxing;
    };

    modules.apps.slipstream = {
      enable = cfg.slipstream.enable;
      sandbox.enable = lib.mkDefault cfg.enableSandboxing;
    };
  };
}
