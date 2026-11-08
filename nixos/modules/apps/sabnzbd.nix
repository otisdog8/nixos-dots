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
  # The internet only: Usenet servers and sabnzbd's self-test host. No LAN or
  # tailnet. Loopback stays open: nginx reaches sabnzbd over it, and DNS goes to
  # resolved's stub (127.0.0.53). So a compromised unpacker still reaches every
  # loopback listener on the host; on recusant nginx, jellyfin (8096), attic
  # (8091), garage's RPC and admin API (3901, 3903), hindsight (8888),
  # postgres (5432, password auth), hermes' dashboard (9119) and Velocity
  # (25600), each with its own authentication. The cgroup IP filter can't
  # narrow it to ports. Of the host's UNIX sockets it reaches only resolved's
  # (DNS stub file, varlink) and nsncd's (/run/nscd); /run is otherwise empty
  # to it, and the nix daemon's socket is hidden (below).
  netpolicy = import ../../../lib/netpolicy.nix { inherit lib; };
  net = netpolicy.lower {
    policy = {
      mode = "internet";
      allow = [ "localhost" ];
      deny = [ ];
      allowDns = true;
    };
    backendDefault = "internet";
    dns = if config.services.resolved.enable then [ "127.0.0.53" ] else config.networking.nameservers;
  };
in
{
  options.modules.apps.${appName} = {
    enable = lib.mkEnableOption "SABnzbd usenet downloader";
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

    writablePaths = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      description = ''
        Folders sabnzbd may write besides its state directory: its incomplete
        and complete download folders (download_dir and complete_dir in the ini).
        Everything else is read-only to it.
      '';
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

        # It downloads and unpacks (unrar, 7z, par2) whatever Usenet serves,
        # so it gets nothing beyond that: its own state, the download folders,
        # the internet. No UMask: the ini's `permissions = 777` is deliberate
        # (sonarr/radarr move the files over NFS).
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = cfg.writablePaths;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        RemoveIPC = true;
        KeyringMode = "private";
        # AF_NETLINK: glibc's getaddrinfo.
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~io_uring_setup io_uring_enter io_uring_register userfaultfd @keyring"
        ];
        SystemCallErrorNumber = "EPERM";
        IPAddressAllow = net.ipAddressAllow;
        IPAddressDeny = net.ipAddressDeny;
        # The IP filter above holds wherever this runs; the slice (netpolicy's,
        # for the sandboxes' netLocal rules) only exists, and so only applies,
        # where modules.sandbox.netLocal is enabled.
        Slice = lib.mkIf config.modules.sandbox.netLocal.enable net.slice;
        # Host UNIX sockets: an empty /run with only what name lookups need
        # bound back, instead of masking each admin socket (the system bus,
        # postgres, tailscaled, the sandbox broker, polkit, ...). A mask of a
        # service's RuntimeDirectory isn't reliable: one made before that
        # service starts is skipped ("-") or fails, and when the service
        # restarts, its rmdir detaches the mask in this namespace and the new
        # directory shows through. An empty /run holds whatever starts later.
        # Bound back ("-": skipped where absent): resolved's directory
        # (/etc/resolv.conf is its stub-resolv.conf; its varlink socket for
        # nss-resolve), nsncd's (NSS through nscd). Its logs go to the
        # journal through the stdout/stderr systemd hands it, not /run.
        TemporaryFileSystem = [ "/run:ro" ];
        BindReadOnlyPaths = [
          "-/run/systemd/resolve"
          "-/run/nscd"
        ];
        # The nix daemon's socket (made at boot by nix-daemon.socket).
        InaccessiblePaths = [ "-/nix/var/nix/daemon-socket" ];
      };
      unitConfig.RequiresMountsFor = cfg.writablePaths;
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
