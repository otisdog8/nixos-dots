# Hyprpaper wallpaper configuration
{
  config,
  lib,
  pkgs,
  username,
  inputs,
  ...
}:
let
  cfg = config.modules.desktop.full.hyprland.hyprpaper;
in
{
  options.modules.desktop.full.hyprland.hyprpaper = {
    enable = lib.mkEnableOption "Hyprpaper wallpaper manager";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.hyprpaper ];

    home-manager.users.${username} = {
      services.hyprpaper = {
        enable = true;
        settings = {
          wallpaper = [
            {
              monitor = "";
              path = "${inputs.self}/images/wallpaper.png";
            }
          ];
        };
      };
    };
  };
}
