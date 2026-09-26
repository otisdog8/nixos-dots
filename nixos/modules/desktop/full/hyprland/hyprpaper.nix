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

    path = lib.mkOption {
      type = lib.types.str;
      default = "${inputs.self}/images/wallpaper.png";
      example = "/home/alice/Pictures/wallpapers";
      description = ''
        Image file, or a directory of images to rotate through (hyprpaper
        cycles a directory natively). A directory outside the repo is read at
        runtime, so its images never enter git or the nix store.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      example = 900;
      description = ''
        Seconds between wallpaper changes, in random order. Only meaningful
        when `path` is a directory; null leaves rotation off.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.hyprpaper ];

    home-manager.users.${username} = {
      services.hyprpaper = {
        enable = true;
        settings = {
          wallpaper = [
            (
              {
                monitor = "";
                path = cfg.path;
              }
              // lib.optionalAttrs (cfg.interval != null) {
                timeout = cfg.interval;
                order = "random";
              }
            )
          ];
          splash = false;
        };
      };
    };
  };
}
