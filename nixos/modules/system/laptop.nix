# Laptop-specific configuration - power management, battery, thermals
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.system.laptop;
in
{
  options.modules.system.laptop = {
    enable = lib.mkEnableOption "laptop power management and features";

    batteryChargeThresholds = {
      start = lib.mkOption {
        type = lib.types.int;
        default = 40;
        description = "Battery charge threshold - start charging when below this percentage";
      };

      stop = lib.mkOption {
        type = lib.types.int;
        default = 80;
        description = "Battery charge threshold - stop charging when above this percentage";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Services
    services = {
      # Power management
      upower.enable = true;
      thermald.enable = true;

      # TLP for battery optimization
      tlp = {
        enable = true;
        settings = {
          CPU_SCALING_GOVERNOR_ON_AC = "performance";
          CPU_SCALING_GOVERNOR_ON_BAT = "powersave";

          CPU_ENERGY_PERF_POLICY_ON_BAT = "balance_power";
          CPU_ENERGY_PERF_POLICY_ON_AC = "performance";

          CPU_MIN_PERF_ON_AC = 0;
          CPU_MAX_PERF_ON_AC = 100;
          CPU_MIN_PERF_ON_BAT = 0;
          CPU_MAX_PERF_ON_BAT = 100;

          # Battery charge thresholds for longevity
          START_CHARGE_THRESH_BAT0 = cfg.batteryChargeThresholds.start;
          STOP_CHARGE_THRESH_BAT0 = cfg.batteryChargeThresholds.stop;
        };
      };

      # Suspend on AC-unplug when already idle: the flag under jrt's runtime dir
      # (uid 1001) is written by hypridle/lid-switch when idle; if present, cat
      # exits 0 and we suspend. Path must match hypridle.nix's $XDG_RUNTIME_DIR/
      # idle-suspend. Also disable USB/PCIe wakeup to prevent suspend battery drain.
      udev.extraRules = ''
        SUBSYSTEM=="power_supply", ATTR{online}=="0", RUN+="${pkgs.bash}/bin/bash -c \"cat /run/user/1001/idle-suspend && systemctl suspend\""
        ACTION=="add", SUBSYSTEM=="usb", TEST=="power/wakeup", ATTR{power/wakeup}="disabled"
        ACTION=="add", SUBSYSTEM=="pci", TEST=="power/wakeup", ATTR{power/wakeup}="disabled"
      '';
    };

    # Persistence for laptop
    environment.persistence."/persist" = {
      directories = [
        "/var/lib/tlp"
        "/var/lib/upower"
      ];
    };
  };
}
