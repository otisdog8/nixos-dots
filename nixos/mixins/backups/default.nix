{ lib, pkgs, ... }:
{
  environment.systemPackages = with pkgs; [ borgbackup ];
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
