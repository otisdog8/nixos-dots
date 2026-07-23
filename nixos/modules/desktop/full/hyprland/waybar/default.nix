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
  # The builtin temperature module reads an arbitrary thermal zone, which on
  # some boards is a motherboard/chipset sensor. Find the CPU package sensor
  # by hwmon name instead (works on both AMD and Intel hosts).
  cpuTempScript = pkgs.writeShellScript "waybar-cputemp" ''
    for d in /sys/class/hwmon/hwmon*; do
      name=$(cat "$d/name" 2>/dev/null)
      case "$name" in
        k10temp|zenpower|coretemp)
          t=$(( $(cat "$d/temp1_input") / 1000 ))
          class=""
          [ "$t" -ge 85 ] && class="critical"
          printf '{"text": "🌡 %s°C", "tooltip": "CPU temperature (%s): %s°C", "class": "%s"}\n' \
            "$t" "$name" "$t" "$class"
          exit 0
          ;;
      esac
    done
    printf '{"text": "🌡 n/a", "tooltip": "no CPU temperature sensor found"}\n'
  '';
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
              "privacy"
              "cpu"
              "custom/cputemp"
              "memory"
              "disk"
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

            # In-use indicators for microphone and screen sharing (icons only
            # appear while active). Camera has no native waybar type, so it isn't
            # shown here. audio-in = mic, screenshare = active screencast/portal.
            "privacy" = {
              "icon-spacing" = 6;
              "icon-size" = 14;
              "transition-duration" = 250;
              "modules" = [
                {
                  "type" = "screenshare";
                  "tooltip" = true;
                }
                {
                  "type" = "audio-in";
                  "tooltip" = true;
                }
              ];
            };

            "custom/cputemp" = {
              "interval" = 5;
              "exec" = "${cpuTempScript}";
              "return-type" = "json";
            };

            "disk" = {
              "interval" = 60;
              "path" = "/";
              "format" = "💾 {free} free";
              "tooltip-format" = "{used} / {total} used on {path} ({percentage_used}%)";
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
                "🪫"
                "🪫"
                "🔋"
                "🔋"
                "🔋"
              ];
            };

            "network" = {
              "format-wifi" = "📶 {essid} ({signalStrength}%)";
              "format-ethernet" = "🌐 {ipaddr}/{cidr}";
              "tooltip-format" = "{ifname} via {gwaddr}";
              "format-linked" = "{ifname} (No IP)";
              "format-disconnected" = "⚠ Disconnected";
            };

            "pulseaudio" = {
              "format" = "{icon} {volume}%";
              "format-bluetooth" = "{icon} {volume}% 🅑";
              "format-muted" = "🔇 muted";
              "format-source" = "🎤 {volume}%";
              "format-source-muted" = "🎤✕";
              "format-icons" = {
                "headphone" = "🎧";
                "hands-free" = "🎧";
                "default" = [
                  "🔈"
                  "🔉"
                  "🔊"
                ];
              };
              "tooltip-format" = "{desc} — {volume}%";
              "on-click" = "pavucontrol";
            };

            "idle_inhibitor" = {
              "format" = "{icon}";
              "format-icons" = {
                "activated" = "☕";
                "deactivated" = "💤";
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
