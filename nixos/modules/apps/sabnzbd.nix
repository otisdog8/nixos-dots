{ config, lib, pkgs, username, ... }:
let
  appName = "sabnzbd";
  cfg = config.modules.apps.${appName};
in
{
  options.modules.apps.${appName} = {
    enable = lib.mkEnableOption "SABnzbd usenet downloader";
    sandbox.enable = lib.mkEnableOption "sandboxing" // { default = false; };
  };

  config = lib.mkIf cfg.enable {
    # Install SABnzbd
    services.sabnzbd.enable = true;

    # Persistence for SABnzbd
    environment.persistence."/persist" = {
      directories = [
        "/var/lib/sabnzbd"
      ];
    };
  };
}
