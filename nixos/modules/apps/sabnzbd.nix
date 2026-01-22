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
  sabnzbdCfg = config.services.sabnzbd;
in
{
  # Disable the built-in NixOS sabnzbd module
  disabledModules = [ "services/networking/sabnzbd.nix" ];

  options.modules.apps.${appName} = {
    enable = lib.mkEnableOption "SABnzbd usenet downloader";
    sandbox.enable = lib.mkEnableOption "sandboxing" // {
      default = false;
    };
    openFirewall = lib.mkEnableOption "opening firewall ports for SABnzbd";
  };

  # Custom sabnzbd service options
  options.services.sabnzbd = {
    enable = lib.mkEnableOption "the sabnzbd server";

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

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open ports in the firewall for the sabnzbd web interface
      '';
    };
  };

  config = lib.mkMerge [
    # Custom sabnzbd service implementation
    (lib.mkIf sabnzbdCfg.enable {
      users.users = lib.mkIf (sabnzbdCfg.user == "sabnzbd") {
        sabnzbd = {
          uid = config.ids.uids.sabnzbd;
          group = sabnzbdCfg.group;
          description = "sabnzbd user";
        };
      };

      users.groups = lib.mkIf (sabnzbdCfg.group == "sabnzbd") {
        sabnzbd.gid = config.ids.gids.sabnzbd;
      };

      systemd.services.sabnzbd = {
        description = "sabnzbd server";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig = {
          Type = "forking";
          GuessMainPID = "no";
          User = sabnzbdCfg.user;
          Group = sabnzbdCfg.group;
          StateDirectory = "sabnzbd";
          ExecStart = "${lib.getBin sabnzbdCfg.package}/bin/sabnzbd -d -f ${sabnzbdCfg.configFile}";
        };
      };

      networking.firewall = lib.mkIf sabnzbdCfg.openFirewall {
        allowedTCPPorts = [ 8080 ];
      };
    })

    # Wrapper module configuration
    (lib.mkIf cfg.enable {
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
    })
  ];
}
