# Networking configuration - NetworkManager, DHCP
{
  config,
  lib,
  pkgs,
  ...
}:
{
  networking.useDHCP = lib.mkDefault true;
  networking.networkmanager = {
    enable = true;
    wifi.scanRandMacAddress = false;
  };

  # Persistence for networking
  environment.persistence."/persist" = {
    directories = [
      "/etc/NetworkManager/system-connections"
    ];
  };
}
