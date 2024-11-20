{
  config,
  inputs,
  lib,
  outputs,
  pkgs,
  stateVersion,
  username,
  ...
}:
let
  inherit (pkgs.stdenv) isDarwin isLinux;
in
{
  programs.hyprlock = {
    enable = true;
    settings = {
      general = {
        no_fade_in = true;
        disable_loading_bar = false;
        hide_cursor = true;
        ignore_empty_input = true;
        text_trim = true;
      };

      background = [
        {
          monitor = "";
          path = "${inputs.self}/images/wallpaper.png";
          #path = "screenshot";
          blur_passes = 3;
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
          shadow_pass = 2;
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
          text = ''cmd[update:1000] echo "$(bash ${inputs.self}/scripts/location.sh) $(bash ${inputs.self}/scripts/weather.sh)"'';
          color = "rgba(255, 255, 255, 1)";
          font_size = 10;
          font_family = "JetBrains Mono Nerd Font Mono ExtraBold";
          position = "0, 800";
          halign = "center";
          valign = "center";
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
      image = [
        {
          monitor = "";
          path = "${inputs.self}/images/face.png";
          border_size = 2;
          border_color = "rgba(255, 255, 0)";
          size = 130;
          rounding = -1;
          rotate = 0;
          reload_time = -1;
          reload_cmd = "";
          position = "0, -150";
          halign = "center";
          valign = "center";
        }
      ];
      "input-field" = [
        {
          monitor = "";
          size = "250, 60";
          outline_thickness = 0;
          outer_color = "rgba(0, 0, 0, 1)";
          dots_size = 0.05;
          dots_spacing = 0.1;
          dots_center = true;
          inner_color = "rgba(0, 0, 0, 1)";
          font_color = "rgba(200, 200, 200, 1)";
          fade_on_empty = false;
          font_family = "JetBrains Mono Nerd Font Mono";
          placeholder_text = ''<span foreground="##cdd6f4"> $USER</span>'';
          hide_input = false;
          position = "0, -275";
          halign = "center";
          valign = "center";
          zindex = 10;
        }
      ];
    };
  };

}
