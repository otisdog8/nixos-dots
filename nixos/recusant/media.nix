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
    (self: super: {
      # Instead of overriding jellyfin-ffmpeg, override ffmpeg_7-full
      ffmpeg_7-full = super.ffmpeg_7-full.override {
        withVpl = true; # <-- note the lowercase “l”
        withMfx = false; # <-- also all lowercase
      };
    })
  ];
}
