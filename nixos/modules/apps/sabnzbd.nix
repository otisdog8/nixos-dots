{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  appName = "sabnzbd";
  cfg = config.modules.apps.${appName};
in
{
  options.modules.apps.${appName} = {
    enable = lib.mkEnableOption "SABnzbd usenet downloader";
    sandbox.enable = lib.mkEnableOption "sandboxing" // {
      default = false;
    };
    openFirewall = lib.mkEnableOption "opening firewall ports for SABnzbd";
  };

  config = lib.mkIf cfg.enable {
    # Install SABnzbd
    services.sabnzbd = {
      enable = true;
      inherit (cfg) openFirewall;
    };

    # Persistence for SABnzbd
    environment.persistence."/persist" = {
      directories = [
        "/var/lib/sabnzbd"
      ];
    };
  };
}
