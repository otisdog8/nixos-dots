# Laptop-specific configuration - power management, battery, thermals
{ config, lib, pkgs, ... }:
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
    # Power management
    services.upower.enable = true;
    services.thermald.enable = true;

    # TLP for battery optimization
    services.tlp = {
      enable = true;
      settings = {
        CPU_SCALING_GOVERNOR_ON_AC = "performance";
        CPU_SCALING_GOVERNOR_ON_BAT = "performance";

        CPU_ENERGY_PERF_POLICY_ON_BAT = "performance";
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

    # Suspend on lid close when unplugged (hypridle file trigger)
    services.udev.extraRules = ''
      SUBSYSTEM=="power_supply", ATTR{online}=="0", RUN+="${pkgs.bash}/bin/bash -c \"cat /tmp/10midle && systemctl suspend\""
    '';

    # Persistence for laptop
    environment.persistence."/persist" = {
      directories = [
        "/var/lib/tlp"
        "/var/lib/upower"
      ];
    };
  };
}
