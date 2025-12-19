# Hypridle idle management configuration
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  cfg = config.modules.desktop.full.hyprland.hypridle;
in
{
  options.modules.desktop.full.hyprland.hypridle = {
    enable = lib.mkEnableOption "Hypridle idle management";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.hypridle ];

    home-manager.users.${username} = {
      services.hypridle = {
        enable = true;
        settings = {
          general = {
            ignore_dbus_inhibit = false;
            ignore_systemd_inhibit = false;
            lock_cmd = "sudo -K && hyprlock";
            unlock_cmd = "pkill -USR1 hyprlock && rm /tmp/10midle";
          };

          listener = [
            {
              timeout = 300;
              on-timeout = "loginctl lock-session";
            }
            {
              timeout = 600;
              on-timeout = "touch /tmp/10midle && test $(cat /sys/class/power_supply/AC0/online) = 0 && systemctl suspend";
            }
            {
              timeout = 450;
              on-timeout = "hyprctl dispatch dpms off";
              on-resume = "hyprctl dispatch dpms on";
            }
          ];
        };
      };
    };
  };
}
