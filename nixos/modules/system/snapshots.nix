# BTRFS snapshot configuration using btrbk
{ config, lib, pkgs, ... }:
let
  cfg = config.modules.system.snapshots;
in
{
  options.modules.system.snapshots = {
    enable = lib.mkEnableOption "BTRFS snapshots with btrbk";

    btrfsRoot = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/btrfs_root";
      description = "Path to the BTRFS root volume";
    };

    snapshotDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/btrfs_root/btrbk_snapshots";
      description = "Directory to store snapshots";
    };

    subvolumes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "persist" "large" "dots" ];
      description = "Subvolumes to snapshot";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = "Snapshot schedule (systemd calendar format)";
    };

    preserveMin = lib.mkOption {
      type = lib.types.str;
      default = "14d";
      description = "Minimum snapshot preservation time";
    };

    preserve = lib.mkOption {
      type = lib.types.str;
      default = "31d 52w 24m 2y";
      description = "Snapshot retention policy";
    };
  };

  config = lib.mkIf cfg.enable {
    services.btrbk = {
      instances = {
        btrbk = {
          onCalendar = cfg.schedule;
          settings = {
            snapshot_preserve_min = cfg.preserveMin;
            snapshot_preserve = cfg.preserve;
            volume = {
              "${cfg.btrfsRoot}" = {
                snapshot_dir = cfg.snapshotDir;
                subvolume = builtins.listToAttrs (
                  map (sv: { name = sv; value = { }; }) cfg.subvolumes
                );
              };
            };
          };
        };
      };
    };
  };
}
