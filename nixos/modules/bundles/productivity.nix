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

    obsidian.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Obsidian";
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
    };

    modules.apps.amazing-marvin = {
      inherit (cfg.amazing-marvin) enable;
    };
  };
}
