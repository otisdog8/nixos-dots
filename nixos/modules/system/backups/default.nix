# Backup configuration using Borgmatic
{ config, lib, pkgs, ... }:
let
  cfg = config.modules.system.backups;
in
{
  options.modules.system.backups = {
    enable = lib.mkEnableOption "backup configuration";

    sourceDirectories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "/persist" ];
      description = "Directories to back up";
    };

    keepDaily = lib.mkOption {
      type = lib.types.int;
      default = 31;
      description = "Number of daily backups to keep";
    };

    keepWeekly = lib.mkOption {
      type = lib.types.int;
      default = 12;
      description = "Number of weekly backups to keep";
    };

    keepMonthly = lib.mkOption {
      type = lib.types.int;
      default = 12;
      description = "Number of monthly backups to keep";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [ borgbackup ];

    services.borgmatic = {
      enable = true;
      settings = {
        source_directories = cfg.sourceDirectories;
        compression = "auto,zstd";
        exclude_caches = true;
        archive_name_format = "{hostname}-{now}";
        keep_daily = cfg.keepDaily;
        keep_weekly = cfg.keepWeekly;
        keep_monthly = cfg.keepMonthly;
      };
    };

    # Persistence for backups
    environment.persistence."/persist" = {
      directories = [
        "/root/.config/borg"
      ];
    };
  };
}
