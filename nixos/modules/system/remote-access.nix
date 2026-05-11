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
    services.tailscale = {
      enable = true;
      openFirewall = true;
      useRoutingFeatures = "both";
    };

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
        X11Forwarding = true;
        PermitRootLogin = "no";

        # Hardened crypto algorithms. Post-quantum KEX listed first to satisfy
        # OpenSSH 9.9+/10 PQ readiness check (store-now-decrypt-later warning).
        KexAlgorithms = [
          "mlkem768x25519-sha256"
          "sntrup761x25519-sha512"
          "sntrup761x25519-sha512@openssh.com"
          "curve25519-sha256"
          "curve25519-sha256@libssh.org"
          "diffie-hellman-group16-sha512"
          "diffie-hellman-group18-sha512"
        ];
        Ciphers = [
          "chacha20-poly1305@openssh.com"
          "aes256-gcm@openssh.com"
          "aes128-gcm@openssh.com"
        ];
        Macs = [
          "hmac-sha2-512-etm@openssh.com"
          "hmac-sha2-256-etm@openssh.com"
          "umac-128-etm@openssh.com"
        ];

        # Authentication & session hardening
        MaxAuthTries = 3;
        LoginGraceTime = 30;
        ClientAliveInterval = 300;
        ClientAliveCountMax = 2;
        HostbasedAuthentication = false;
        PermitEmptyPasswords = false;
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
