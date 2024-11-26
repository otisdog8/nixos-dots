{ lib, pkgs, ... }:
{
  environment.systemPackages = with pkgs; [ borgbackup ];
  services.btrbk = {
    instances = {
      btrbk = {
        onCalendar = "hourly";
        settings = {
          snapshot_preserve_min = "14d";
          snapshot_preserve = "31d 52w 24m 2y";
          volume = {
            "/mnt/btrfs_root" = {
              snapshot_dir = "/mnt/btrfs_root/btrbk_snapshots";
              subvolume = {
                "persist" = {};
                "large" = {};
                "dots" = {};
              };
            };
          };
        };
      };
    };
  };
services.borgmatic = {
enable = true;
settings = {
source_directories = ["/persist"];
compression = "auto,zstd";
exclude_caches = true;
archive_name_format= "{hostname}-{now}";
keep_daily = 31;
keep_weekly = 12;
keep_monthly = 12;
};
};

}
