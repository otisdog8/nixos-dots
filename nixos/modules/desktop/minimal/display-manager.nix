# Minimal display manager configuration
{ config, lib, pkgs, ... }:
let
  cfg = config.modules.desktop.minimal.display-manager;
in
{
  options.modules.desktop.minimal.display-manager = {
    enable = lib.mkEnableOption "minimal display manager";
  };

  config = lib.mkIf cfg.enable {
    # Use lightdm for minimal desktop
    services.xserver.enable = true;
    services.xserver.displayManager.lightdm.enable = true;
  };
}
