# Hyprlock screen locker configuration
{ config, lib, pkgs, username, inputs, ... }:
let
  cfg = config.modules.desktop.full.hyprland.hyprlock;
in
{
  options.modules.desktop.full.hyprland.hyprlock = {
    enable = lib.mkEnableOption "Hyprlock screen locker";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.hyprlock ];

    home-manager.users.${username} = {
      programs.hyprlock = {
        enable = true;
        settings = {
          general = {
            hide_cursor = true;
            ignore_empty_input = true;
            text_trim = true;
          };

          background = [
            {
              monitor = "";
              path = "${inputs.self}/images/wallpaper.png";
              blur_passes = 0;
              contrast = 0.8916;
              brightness = 0.7172;
              vibrancy = 0.1696;
              vibrancy_darkness = 0;
            }
          ];

          label = [
            {
              monitor = "";
              text = ''cmd[update:1000] echo -e "$(date +"%H")"'';
              color = "rgba(255, 255, 255, 1)";
              shadow_size = 3;
              shadow_color = "rgb(0,0,0)";
              shadow_boost = 1.2;
              font_size = 150;
              font_family = "AlfaSlabOne";
              position = "0, -250";
              halign = "center";
              valign = "top";
            }
            {
              monitor = "";
              text = ''cmd[update:1000] echo -e "$(date +"%M")"'';
              color = "rgba(255, 255, 255, 1)";
              font_size = 150;
              font_family = "AlfaSlabOne";
              position = "0, -420";
              halign = "center";
              valign = "top";
            }
            {
              monitor = "";
              text = ''cmd[update:1000] echo -e "$(date +"%d %b %A")"'';
              color = "rgba(255, 255, 255, 1)";
              font_size = 14;
              font_family = "JetBrains Mono Nerd Font Mono ExtraBold";
              position = "0, 50";
              halign = "center";
              valign = "bottom";
            }
            {
              monitor = "";
              text = ''cmd[update:1000] echo -e "$(${inputs.self}/scripts/infonlock.sh)"'';
              color = "rgba(255, 255, 255, 1)";
              font_size = 12;
              font_family = "JetBrains Mono Nerd Font Mono ExtraBold";
              position = "-20, -510";
              halign = "right";
              valign = "center";
            }
          ];
          "input-field" = [
            {
              monitor = "";
              size = "750, 60";
              outline_thickness = 0;
              outer_color = "rgba(0, 0, 0, 0)";
              dots_size = 0.05;
              dots_spacing = 0.1;
              dots_center = true;
              inner_color = "rgba(0, 0, 0, 0)";
              font_color = "rgba(200, 200, 200, 1)";
              fade_on_empty = false;
              font_family = "JetBrains Mono Nerd Font Mono";
              placeholder_text = ''<span foreground="##cdd6f4"> $USER</span>'';
              hide_input = false;
              position = "0, -275";
              halign = "center";
              valign = "center";
              zindex = 10;
            }
          ];
        };
      };
    };
  };
}
