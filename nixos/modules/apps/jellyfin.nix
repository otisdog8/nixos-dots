{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  appName = "jellyfin";
  cfg = config.modules.apps.${appName};
  sbx = cfg.sandbox;
  jf = config.services.jellyfin;

  # The internet (metadata providers, the plugin repository), loopback (nginx
  # proxies to it there; DNS goes to resolved's stub) and sbx.allowAddresses.
  # Not the LAN, link-local or multicast, nor the host's own public addresses
  # (the slice, as for sabnzbd). systemd's IP filter matches the remote
  # address both ways, so this is also who can connect to it.
  netpolicy = import ../../../lib/netpolicy.nix { inherit lib; };
  net = netpolicy.lower {
    policy = {
      mode = "internet";
      allow = [ "localhost" ] ++ sbx.allowAddresses;
      deny = [ ];
      allowDns = true;
    };
    backendDefault = "internet";
    dns = if config.services.resolved.enable then [ "127.0.0.53" ] else config.networking.nameservers;
  };

  # hardware.graphics' driver env (/run/opengl-driver's target): VA-API, QSV
  # (oneVPL) and OpenCL find their drivers there.
  drivers = config.systemd.tmpfiles.settings.graphics-driver."/run/opengl-driver"."L+".argument or null;
in
{
  options.modules.apps.${appName} = {
    enable = lib.mkEnableOption "Jellyfin media server";
    openFirewall = lib.mkEnableOption "opening firewall ports for Jellyfin";

    sandbox = {
      enable = lib.mkEnableOption ''
        a tighter sandbox than nixpkgs' unit: a read-only system but for
        Jellyfin's own directories, no home directories, only the GPU's DRM
        nodes among devices, an empty /run, and the internet but not the LAN.
        Jellyfin runs ffmpeg on every file a library holds, downloaded media
        included, so a malicious file needs no login to reach it
      '';

      mediaPaths = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        example = [ "/media" ];
        description = ''
          The library folders. Read-only to Jellyfin (as everything outside
          its own directories is); listed so the unit waits for their mounts.
          Read-only means that what Jellyfin would save next to the media
          (NFO files, artwork, subtitles and lyrics it downloads, trickplay
          with "save with media" on) fails and is logged; playback, scans and
          transcoding don't need it. To allow it, list the folder in
          writablePaths instead.
        '';
      };

      writablePaths = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = ''
          Folders Jellyfin may write besides its data, config, log and cache
          directories (where the transcode, trickplay and extraction caches
          live by default): a transcoding path set elsewhere in the dashboard,
          or library folders it should save into.
        '';
      };

      allowAddresses = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        example = [
          "100.64.0.0/10"
          "fd7a:115c:a1e0::/48"
        ];
        description = ''
          Non-internet addresses (IPAddressAllow= syntax) Jellyfin may reach
          and be reached from, besides loopback: clients and services that
          connect to port 8096 directly instead of through the proxy, and
          webhooks or notifications it sends to the LAN or tailnet.
        '';
      };

      gpu = lib.mkOption {
        type = lib.types.bool;
        default = config.hardware.graphics.enable;
        defaultText = lib.literalExpression "config.hardware.graphics.enable";
        description = ''
          Hardware transcoding and tone mapping (VA-API, QSV, OpenCL): the DRM
          device nodes (/dev/dri) and the graphics drivers. Off, it gets a
          private /dev with only the pseudo devices.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Install Jellyfin
    services.jellyfin = {
      enable = true;
      package = pkgs.jellyfin;
      inherit (cfg) openFirewall;
    };

    # On top of nixpkgs' unit (services/misc/jellyfin.nix), which already has
    # no capabilities, a user namespace (PrivateUsers), PrivateTmp, the
    # @system-service syscall allowlist, ProtectProc/ProcSubset and the
    # kernel-tunable/module/log protections.
    systemd.services.jellyfin = lib.mkIf sbx.enable {
      # The driver env is bound by path (below), so a new one needs a restart.
      restartTriggers = lib.optional (sbx.gpu && drivers != null) drivers;
      unitConfig.RequiresMountsFor = sbx.mediaPaths ++ sbx.writablePaths;
      serviceConfig = {
        # nixpkgs' `true` leaves /etc, /var and every mount writable to it
        # wherever the jellyfin user's permissions allow (sabnzbd's downloads
        # are 0777).
        ProtectSystem = lib.mkForce "strict";
        ReadWritePaths = [
          jf.dataDir
          jf.configDir
          jf.logDir
          jf.cacheDir
        ]
        ++ sbx.writablePaths;
        ProtectHome = true;

        # Devices: the DRM nodes (render and card, all GPUs) and the standard
        # pseudo devices only. Many others are 0666 to every user (/dev/kvm,
        # /dev/fuse, /dev/net/tun). PrivateDevices would hide /dev/dri too.
        PrivateDevices = !sbx.gpu;
        DevicePolicy = "closed";
        DeviceAllow = lib.optional sbx.gpu "char-drm rw";

        # After nixpkgs' "@system-service" "~@privileged": the first entry
        # sets allowlist mode, so these must come after it. io_uring is root's
        # and the io_uring group's only anyway (hardening.nix's sysctl).
        SystemCallFilter = lib.mkAfter [
          "~io_uring_setup io_uring_enter io_uring_register userfaultfd @keyring"
        ];
        KeyringMode = "private";

        IPAddressAllow = net.ipAddressAllow;
        IPAddressDeny = net.ipAddressDeny;
        Slice = lib.mkIf config.modules.sandbox.netLocal.enable net.slice;

        # Host UNIX sockets: an empty /run, as for sabnzbd (see sabnzbd.nix for
        # why not masks), with name lookups' sockets and the graphics drivers
        # bound back. Its logs go to the journal through stdout/stderr.
        TemporaryFileSystem = [ "/run:ro" ];
        BindReadOnlyPaths = [
          "-/run/systemd/resolve"
          "-/run/nscd"
        ]
        ++ lib.optional sbx.gpu "-/run/opengl-driver";
        InaccessiblePaths = [ "-/nix/var/nix/daemon-socket" ];
      };
    };

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
