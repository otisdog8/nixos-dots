{ config, lib, pkgs, username, ... }:
let
  appName = "jellyfin";
  cfg = config.modules.apps.${appName};
in
{
  options.modules.apps.${appName} = {
    enable = lib.mkEnableOption "Jellyfin media server";
    sandbox.enable = lib.mkEnableOption "sandboxing" // { default = false; };
  };

  config = lib.mkIf cfg.enable {
    # Install Jellyfin
    services.jellyfin.enable = true;
    services.jellyfin.package = pkgs.jellyfin;

    # Persistence for Jellyfin
    environment.persistence."/persist" = {
      directories = [
        "/var/lib/jellyfin"
      ];
    };

    environment.persistence."/cache" = {
      directories = [
        "/var/cache/jellyfin"
      ];
    };
  };
}
