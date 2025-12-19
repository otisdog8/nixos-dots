# Minimal window manager configuration
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.desktop.minimal.window-manager;
in
{
  options.modules.desktop.minimal.window-manager = {
    enable = lib.mkEnableOption "minimal window manager";
  };

  config = lib.mkIf cfg.enable {
    # Use i3 as minimal window manager
    services.xserver.windowManager.i3.enable = true;

    environment.systemPackages = with pkgs; [
      i3status
      dmenu
      feh # For wallpapers
    ];
  };
}
