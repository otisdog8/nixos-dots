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

    oledMonitors = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "desc:ASUSTek COMPUTER INC PG32UCDM3 W4LMAV007023" ];
      description = ''
        OLED panels (connector name or `desc:` selector) to power off on a
        much shorter idle timeout than the global dpms ladder. Powering the
        panel off is the burn-in protection: emission stops and the monitor's
        own pixel-refresh/panel-care cycles can run while it is in standby.
        Any input turns it back on (mouse_move/key_press_enables_dpms).
      '';
    };

    oledTimeout = lib.mkOption {
      type = lib.types.int;
      default = 150;
      description = "Seconds of idle before OLED monitors are powered off.";
    };
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
            # Lock on EVERY suspend path, not just the idle ladder. Without this,
            # a suspend triggered outside the idle timeouts — lid close, manual
            # `systemctl suspend`, the AC-unplug udev rule (laptop.nix) — sleeps
            # the machine UNLOCKED, so it wakes straight to the desktop (a
            # data-exposure gap, sharper here given impermanence + at-rest
            # secrets). hypridle takes a logind sleep-delay inhibitor while
            # before_sleep_cmd runs, giving hyprlock time to grab the screen
            # before the machine actually suspends; after_sleep_cmd repaints the
            # display on resume so it isn't left blanked behind the lock.
            before_sleep_cmd = "loginctl lock-session";
            after_sleep_cmd = "hyprctl dispatch dpms on";
          };

          listener =
            # OLED burn-in guard: blank just the OLED panels well before the
            # global dpms timeout. hypridle keys off seat-wide idle, so this
            # cannot catch "static content on the OLED while typing on another
            # monitor" — it shortens the window where an idle desktop keeps
            # the panel lit. dpms takes a monitor selector, so only these
            # outputs go dark; the global `dpms on` on resume relights them.
            lib.optional (cfg.oledMonitors != [ ]) {
              timeout = cfg.oledTimeout;
              on-timeout = lib.concatMapStringsSep " && " (
                m: ''hyprctl dispatch dpms "off ${m}"''
              ) cfg.oledMonitors;
              on-resume = "hyprctl dispatch dpms on";
            }
            ++ [
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
