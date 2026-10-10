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

  # Hyprland runs the Lua config parser, where `hyprctl dispatch <arg>` is
  # eval'd as `hl.dispatch(<arg>)` — so <arg> must be a Lua dispatcher
  # expression. The legacy `dispatch dpms off` form is a Lua syntax error there
  # and fails silently (monitors never blank).
  dpms =
    action: monitor:
    let
      mon = lib.optionalString (monitor != null) '', monitor = "${monitor}"'';
    in
    "hyprctl dispatch '${''hl.dsp.dpms({ action = "${action}"${mon} })''}'";

  # Blank all monitors shortly after locking. Every lock path (CTRL+ALT+l,
  # wlogout, idle ladder, before_sleep) funnels through lock_cmd, so this is the
  # one place to do it. The delay lets hyprlock grab the screen first and keeps
  # the pointer motion / key press that triggered the lock from instantly
  # re-enabling dpms (mouse_move/key_press_enables_dpms). Wall-clock guard: when
  # the lock came from before_sleep_cmd the machine suspends mid-sleep, and
  # without it this would fire on resume and undo after_sleep_cmd's `dpms on`.
  blankAfterLock = ''(s=$(date +%s); sleep 2; [ $(( $(date +%s) - s )) -le 5 ] && ${dpms "off" null}) &'';

  # Exit 0 only when on battery. Glob over A* (AC0/ACAD/ADP1/…) instead of the
  # old hardcoded AC0, so it works on any laptop's supply naming.
  # cfg.presenceCommand, told "idle", "active", "locked" or "unlocked". Never
  # in the way of locking: in the background, its failure ignored.
  presence =
    state: lib.optionalString (cfg.presenceCommand != null) "(${cfg.presenceCommand} ${state} >/dev/null 2>&1 &) ; ";
  # After hyprlock exits: unlocked, unless this was a second lock_cmd while
  # the screen was already locked (that hyprlock exits at once).
  presenceUnlocked = lib.optionalString (cfg.presenceCommand != null) " ; ${pkgs.procps}/bin/pgrep -x hyprlock >/dev/null || ${cfg.presenceCommand} unlocked >/dev/null 2>&1";

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

    presenceCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        A command told whether the user is at this desktop: called with
        "idle" / "active" (presenceTimeout without input, and back) and
        "locked" / "unlocked" (around hyprlock). Set by agent-auth's hostd
        (modules/system/agent-auth-daemons.nix) for its desktop prompts.
      '';
    };

    presenceTimeout = lib.mkOption {
      type = lib.types.int;
      default = 120;
      description = "Seconds without input before presenceCommand is told \"idle\".";
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
            lock_cmd = "${presence "locked"}${blankAfterLock} sudo -K && hyprlock${presenceUnlocked}";
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
            after_sleep_cmd = dpms "on" null;
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
              on-timeout = lib.concatMapStringsSep " && " (dpms "off") cfg.oledMonitors;
              on-resume = dpms "on" null;
            }
            ++ lib.optional (cfg.presenceCommand != null) {
              timeout = cfg.presenceTimeout;
              on-timeout = "${cfg.presenceCommand} idle";
              on-resume = "${cfg.presenceCommand} active";
            }
            ++ [
            {
              timeout = 300;
              on-timeout = "loginctl lock-session";
            }
            {
              timeout = 450;
              on-timeout = dpms "off" null;
              on-resume = dpms "on" null;
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
