# Communication applications bundle
{ config, lib, ... }:
let
  cfg = config.modules.bundles.communication;
in
{
  imports = [
    ../apps/vesktop.nix
    ../apps/zoom.nix
  ];

  options.modules.bundles.communication = {
    enable = lib.mkEnableOption "communication applications bundle";

    vesktop.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Vesktop (Discord client)";
    };

    zoom.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Zoom";
    };
  };

  config = lib.mkIf cfg.enable {
    modules.apps.vesktop = {
      inherit (cfg.vesktop) enable;
    };

    modules.apps.zoom = {
      inherit (cfg.zoom) enable;
    };
  };
}
