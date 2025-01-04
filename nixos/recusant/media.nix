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

  nixpkgs.overlays = [
        (final: prev: {
          jellyfin-ffmpeg = prev.jellyfin-ffmpeg.override {
            withVpl = true;
            withMfx = false;
          };
        })
      ];
}
