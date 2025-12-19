# Productivity applications bundle
{ config, lib, ... }:
let
  cfg = config.modules.bundles.productivity;
in
{
  imports = [
    ../apps/obsidian.nix
    ../apps/amazing-marvin.nix
  ];

  options.modules.bundles.productivity = {
    enable = lib.mkEnableOption "productivity applications bundle";

    enableSandboxing = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable sandboxing for all productivity apps in the bundle";
    };

    obsidian.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Obsidian";
    };

    obsidian.vaultPath = lib.mkOption {
      type = lib.types.str;
      default = "Documents/obsidian";
      description = "Path to Obsidian vault relative to home directory";
    };

    amazing-marvin.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Amazing Marvin";
    };
  };

  config = lib.mkIf cfg.enable {
    modules.apps.obsidian = {
      inherit (cfg.obsidian) enable;
      sandbox.enable = lib.mkDefault cfg.enableSandboxing;
      inherit (cfg.obsidian) vaultPath;
    };

    modules.apps.amazing-marvin = {
      inherit (cfg.amazing-marvin) enable;
      sandbox.enable = lib.mkDefault cfg.enableSandboxing;
    };
  };
}
