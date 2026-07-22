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

  # Only laptops idle-suspend; desktops/servers (recusant) get lock + dpms only.
  isLaptop = config.modules.system.laptop.enable;

  # Idle-suspend coordination flag, per-user under XDG_RUNTIME_DIR (was
  # world-writable /tmp/10midle). hypridle writes it when idle; laptop.nix's
  # AC-unplug udev rule reads it to suspend immediately when power is pulled
  # while already idle. hypridle runs commands via sh, so $XDG_RUNTIME_DIR
  # expands at runtime.
  idleFlag = "$XDG_RUNTIME_DIR/idle-suspend";

  # Exit 0 only when on battery. Glob over A* (AC0/ACAD/ADP1/…) instead of the
  # old hardcoded AC0, so it works on any laptop's supply naming.
  onBattery = ''test "$(cat /sys/class/power_supply/A*/online 2>/dev/null | head -n1)" = 0'';
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
            unlock_cmd = "pkill -USR1 hyprlock && rm -f ${idleFlag}";
          };

          listener = [
            {
              timeout = 300;
              on-timeout = "loginctl lock-session";
            }
            {
              timeout = 450;
              on-timeout = "hyprctl dispatch dpms off";
              on-resume = "hyprctl dispatch dpms on";
            }
          ]
          # Laptops only: after lock + dpms, mark idle and suspend if on
          # battery. The flag also lets the AC-unplug udev rule (laptop.nix)
          # suspend at once when power is pulled while already idle.
          ++ lib.optional isLaptop {
            timeout = 600;
            on-timeout = "touch ${idleFlag} && ${onBattery} && systemctl suspend";
            on-resume = "rm -f ${idleFlag}";
          };
        };
      };
    };
  };
}
