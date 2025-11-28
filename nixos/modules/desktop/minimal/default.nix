# Minimal desktop environment - lightweight X11/Wayland setup
{ config, lib, ... }:
let
  cfg = config.modules.desktop.minimal;
in
{
  imports = [
    ./display-manager.nix
    ./window-manager.nix
  ];

  options.modules.desktop.minimal = {
    enable = lib.mkEnableOption "minimal desktop environment";
  };

  config = lib.mkIf cfg.enable {
    # Enable minimal display and window manager
    modules.desktop.minimal.display-manager.enable = lib.mkDefault true;
    modules.desktop.minimal.window-manager.enable = lib.mkDefault true;
  };
}
