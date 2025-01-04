{ config, pkgs, ... }:

{
  services.sabnzbd = {
    enable = true;
    openFirewall = true;
  };

  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };
}
