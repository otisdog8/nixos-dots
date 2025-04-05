{ lib, pkgs, ... }:
{
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
                "mc" = { };
              };
            };
          };
        };
      };
    };
  };
}
