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
  services.hypridle = {
    enable = true;
    settings = {
      general = {
        ignore_dbus_inhibit = false;
        ignore_systemd_inhibit = false;
        lock_cmd = "hyprlock";
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
      ];
    };
  };
}
