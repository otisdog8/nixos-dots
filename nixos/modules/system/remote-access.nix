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
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP/Ue/yVo+tbYIPCRAmIEPNbwQWctjPUnhgICrgDqHc2 root@excelsior"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDh9fZN0PYM8E4yYCBPsAZcnBl0xbBfC7rH6w3cxV5+1 root@galaxy"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAgWOz/HGTcO8CJy67MvX6da4Ufelxy6ocbivhBa6hyg root@constitution"
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

    # tailscaled logs on its own critical path: every logf() calls
    # logtail.Write -> filch.Write -> a synchronous write() to the on-disk log
    # buffer, serialized under logtail.writeLock (logtail/logtail.go). On k3s
    # nodes that buffer lives in $STATE_DIRECTORY (/var/lib/tailscale) on the
    # same luks/btrfs device rook-ceph's loopback disk.img saturates, so that
    # write() stalls in balance_dirty_pages / behind btrfs transaction commits;
    # the held writeLock then blocks every other logging goroutine and the
    # daemon freezes. Relocate the buffer to tmpfs (/run) via TS_LOGS_DIR, which
    # logpolicy honours ahead of $STATE_DIRECTORY (logpolicy/logpolicy.go:204).
    # This is exactly what tailscale does for Synology/QNAP (issue #3551).
    # Tradeoff: buffered logs and the logtail ID reset on reboot instead of
    # being uploaded later — fine for these nodes.
    #
    # Second stall vector: tailscaled echoes every level-0 log line to stderr
    # on its logf goroutine, before taking any lock (logtail.go:883). Under
    # systemd that stderr is a backpressuring socket to journald; when journald
    # blocks writing its persistent journal to the same contended disk it stops
    # draining the socket and the echo write() blocks, freezing the daemon.
    # There is no app-level knob to disable the echo (StderrLevel is fixed at 0),
    # so send the unit's stdout/stderr to null to take journald off the path.
    # Nothing is lost: filch already keeps a superset on tmpfs — logtail writes
    # every line to a self-rotating ~50MB ring buffer (TS_LOGS_DIR below) and
    # dup2's fd 2 into that same buffer, so panics land there too; read it live
    # with `tailscale debug daemon-logs`. (A file: redirect would instead grow
    # unbounded on tmpfs — a RAM leak on these swapless nodes. Only the few
    # pre-logtail-init startup lines are lost to null.)
    #
    # Also keep it resident and unkillable under memory pressure: a reclaimed
    # page re-faulted from the saturated disk is its own multi-second stall.
    # (I/O-scheduler knobs like IOWeight/ionice are deliberately omitted — they
    # reorder the block queue but do nothing for a write() stuck in dirty-page
    # throttling or a btrfs commit, which is the actual failure mode here.)
    systemd.services.tailscaled.serviceConfig = {
      Environment = [ "TS_LOGS_DIR=%t/tailscale" ]; # %t = /run (tmpfs)
      StandardOutput = "null";
      StandardError = "null";
      OOMScoreAdjust = -900;
      MemoryLow = "128M";
    };

    # Enable debug info
    environment.enableDebugInfo = true;

    # OpenSSH server
    services.openssh = {
      enable = true;
      ports = [ 22 ];
      # Do NOT honour ~/.ssh/authorized_keys. Under impermanence the user's
      # ~/.ssh is (was) persisted and writable, so a home-folder compromise
      # could drop an authorized_keys entry that survives reboot — a permanent
      # remote backdoor. With this off, sshd only reads keys from
      # /etc/ssh/authorized_keys.d/%u, which NixOS generates read-only from the
      # declarative `authorizedKeys.keys` below (in wiped, non-persistent /etc).
      authorizedKeysInHomedir = false;
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

    # Firewall enable lives in networking.nix; declare just the SSH port.
    # tailscale0 is in trustedInterfaces so administrative SSH-over-tailnet
    # works regardless.
    networking.firewall.allowedTCPPorts = [ 22 ];

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
