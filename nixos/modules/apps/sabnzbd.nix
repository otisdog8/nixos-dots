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

    package = lib.mkPackageOption pkgs "sabnzbd" { };

    configFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/sabnzbd/sabnzbd.ini";
      description = "Path to config file.";
    };

    user = lib.mkOption {
      default = "sabnzbd";
      type = lib.types.str;
      description = "User to run the service as";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "sabnzbd";
      description = "Group to run the service as";
    };
  };

  config = lib.mkIf cfg.enable {
    # Create user and group
    users.users = lib.mkIf (cfg.user == "sabnzbd") {
      sabnzbd = {
        isSystemUser = true;
        group = cfg.group;
        description = "sabnzbd user";
      };
    };

    users.groups = lib.mkIf (cfg.group == "sabnzbd") {
      sabnzbd = { };
    };

    # Custom sabnzbd systemd service
    systemd.services.sabnzbd = {
      description = "sabnzbd server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        Type = "forking";
        GuessMainPID = "no";
        User = cfg.user;
        Group = cfg.group;
        StateDirectory = "sabnzbd";
        # Pin the listener to loopback (--server overrides the persisted ini's
        # host/port). nginx proxies to 127.0.0.1:8080, so this forces ALL access
        # through the TLS/auth reverse proxy — a tailnet peer can't hit the raw
        # backend directly even though tailscale0 is a trusted firewall interface.
        ExecStart = "${lib.getBin cfg.package}/bin/sabnzbd -d -f ${cfg.configFile} --server 127.0.0.1:8080";
      };
    };

    # Firewall configuration
    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [ 8080 ];
    };

    # Persistence for SABnzbd
    environment.persistence."/persist" = {
      directories = [
        "/var/lib/sabnzbd"
      ];
    };
  };
}
