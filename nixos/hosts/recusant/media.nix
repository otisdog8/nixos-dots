# Recusant media server configuration
{ config, pkgs, ... }:
{
  imports = [
    ../../modules/apps/jellyfin.nix
    ../../modules/apps/sabnzbd.nix
  ];

  modules.apps.jellyfin = {
    enable = true;
    openFirewall = true;
  };

  modules.apps.sabnzbd = {
    enable = true;
    openFirewall = true;
  };
}
