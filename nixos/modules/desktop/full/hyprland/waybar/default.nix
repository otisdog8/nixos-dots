# Waybar configuration for Hyprland
{
  config,
  lib,
  pkgs,
  username,
  inputs,
  ...
}:
let
  cfg = config.modules.desktop.full.hyprland.waybar;
  betterTransition = "all 0.3s cubic-bezier(.55,-0.68,.48,1.682)";
  clock24h = true;
in
{
  options.modules.desktop.full.hyprland.waybar = {
    enable = lib.mkEnableOption "Waybar status bar";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.waybar ];

    home-manager.users.${username} = {
      programs.waybar = {
        enable = true;
        package = pkgs.waybar;
        settings = [
          {
            "spacing" = 0;

            "modules-left" = [
              "hyprland/workspaces"
              "hyprland/submap"
              "sway/scratchpad"
              "hyprland/window"
            ];
            "modules-right" = [
              "cpu"
              "memory"
              "backlight"
              "pulseaudio"
              "battery"
              "network"
              "tray"
              "clock"
              "idle_inhibitor"
            ];

            "custom/power" = {
              "format" = "goecho";
              "tooltip-format" = "power manager";
              "on-click" = "wlogout -b 2 -c 0 -r 0 -m 0 --protocol layer-shell";
            };

            "clock" = {
              "interval" = 30;
              "format" = "{:%a %d %b %Y | %H:%M %p}";
              "tooltip-format" = "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>";
            };

            "cpu" = {
              "interval" = 1;
              "format" = "CPU = {usage}%";
            };

            "memory" = {
              "interval" = 1;
              "format" = "Mem ={}%";
            };

            "backlight" = {
              "format" = "{icon} {percent}%";
              "format-icons" = [
                "🔅"
                "🔆"
              ];
            };

            "battery" = {
              "states" = {
                "warning" = 30;
                "critical" = 15;
              };
              "interval" = 1;
              "format" = "{icon} {capacity}%";
              "format-charging" = "⚡ {capacity}%";
              "format-icons" = [
                ""
                ""
                ""
                ""
                ""
              ];
            };

            "network" = {
              "format-wifi" = " ({signalStrength}%) {essid}";
              "format-ethernet" = "{ipaddr}/{cidr} ";
              "tooltip-format" = "{ifname} via {gwaddr} ";
              "format-linked" = "{ifname} (No IP) ";
              "format-disconnected" = "Disconnected ⚠";
            };

            "pulseaudio" = {
              "format" = "{icon} {volume}%";
              "format-bluetooth" = "{icon} {volume}%";
              "format-muted" = " {format_source}";
              "format-source" = " {volume}%";
              "format-source-muted" = "";
              "format-icons" = {
                "headphone" = "";
                "hands-free" = "";
                "default" = [
                  ""
                  ""
                  ""
                ];
              };
              "on-click" = "pavucontrol";
            };

            "idle_inhibitor" = {
              "format" = "{icon}";
              "format-icons" = {
                "activated" = "";
                "deactivated" = "";
              };
            };

            "tray" = {
              "spacing" = 10;
            };
          }
        ];
        style = builtins.readFile (inputs.self + "/config/waybar");
      };
    };
  };
}
