# Remote access configuration - SSH, Tailscale
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  cfg = config.modules.system.remote-access;

  # SSH keys for all hosts
  sshKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICPtgHM9vEd6NR70wKznoP/HE3aCrud/9rx/2Lu16Dh4 jrt@excelsior"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKrESH5ZwJ9UprxxlPHlwMTLZtNiFysHR+5CHcTA63+a jrt@constitution"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID8cRRtLtbuTMeLNvA4oB1Ui0yk0yhdPTPBvqku6lQZj jrt@galaxy"
  ];
in
{
  options.modules.system.remote-access = {
    enable = lib.mkEnableOption "remote access (SSH, Tailscale)";
  };

  config = lib.mkIf cfg.enable {
    # Tailscale VPN
    services.tailscale.enable = true;
    services.tailscale.openFirewall = true;
    services.tailscale.useRoutingFeatures = "both";

    # Enable debug info
    environment.enableDebugInfo = true;

    # OpenSSH server
    services.openssh = {
      enable = true;
      ports = [ 22 ];
      settings = {
        PasswordAuthentication = true;
        AllowUsers = null; # Allows all users by default
        UseDns = true;
        X11Forwarding = false;
        PermitRootLogin = "no";
      };
    };

    networking.firewall.allowedTCPPorts = [ 22 ];
    networking.firewall.enable = true;

    # SSH authorized keys for users
    users.users.root.openssh.authorizedKeys.keys = sshKeys;
    users.users.${username}.openssh.authorizedKeys.keys = sshKeys;

    # Persistence for remote access
    environment.persistence."/persist" = {
      directories = [
        "/var/lib/tailscale"
      ];
      files = [
        "/etc/ssh/ssh_host_ed25519_key"
        "/etc/ssh/ssh_host_ed25519_key.pub"
        "/etc/ssh/ssh_host_rsa_key"
        "/etc/ssh/ssh_host_rsa_key.pub"
      ];
    };
  };
}
