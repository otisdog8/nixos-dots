# K3s Kubernetes cluster configuration
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.system.k3s;
in
{
  imports = [
    ./secrets.nix
  ];

  options.modules.system.k3s = {
    enable = lib.mkEnableOption "K3s Kubernetes cluster";

    clusterInit = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Initialize a new cluster (first server node)";
    };

    serverAddr = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Address of the k3s server to join (for agent/secondary nodes)";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra flags to pass to k3s (e.g. bind-address, node-ip)";
    };

    persistDir = lib.mkOption {
      type = lib.types.str;
      default = "/large";
      description = ''
        Persistence root (impermanence) for k3s/rook/etcd state. Nodes refactored
        onto the dedicated XFS data volume set this to "/data" so etcd's fsync
        stream lands on XFS instead of the btrfs pool; un-refactored nodes keep
        the historical "/large" btrfs subvolume.
      '';
    };

    cephLoopback = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Back the rook OSD with the /large/disk.img loopback device (old layout).
        Set false on nodes where Ceph has its own raw partition — rook consumes
        the partition directly and the k3sloop losetup service is dropped.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # tailscale0 is trusted globally in networking.nix, so these allow-lists
    # are only needed if a host ever drops trustedInterfaces. Keep them
    # declared as documentation + a safety net.
    networking.firewall = {
      allowedTCPPorts = [
        4240 # cluster health checks (cilium-health)
        4244 # Hubble server
        4245 # Hubble Relay
        4250 # Mutual Authentication port
        4251 # Spire Agent health check port (listening on 127.0.0.1 or ::1)
        6060 # cilium-agent pprof server (listening on 127.0.0.1)
        6061 # cilium-operator pprof server (listening on 127.0.0.1)
        6062 # Hubble Relay pprof server (listening on 127.0.0.1)
        9878 # cilium-envoy health listener (listening on 127.0.0.1)
        9879 # cilium-agent health status API (listening on 127.0.0.1 and/or ::1)
        9890 # cilium-agent gops server (listening on 127.0.0.1)
        9891 # operator gops server (listening on 127.0.0.1)
        9893 # Hubble Relay gops server (listening on 127.0.0.1)
        9901 # cilium-envoy Admin API (listening on 127.0.0.1)
        9962 # cilium-agent Prometheus metrics
        9963 # cilium-operator Prometheus metrics
        9964 # cilium-envoy Prometheus metrics
        6443 # k3s: required so that pods can reach the API server (running on port 6443 by default)
        2379 # k3s, etcd clients: required if using a "High Availability Embedded etcd" configuration
        2380 # k3s, etcd peers: required if using a "High Availability Embedded etcd" configuration
      ];

      allowedUDPPorts = [
        51871 # WireGuard encryption tunnel endpoint
      ];
    };

    environment.systemPackages = with pkgs; [
      k3s
    ];

    services.k3s = {
      enable = true;
      role = "server";
      inherit (cfg) clusterInit;
      serverAddr = lib.mkIf (cfg.serverAddr != null) cfg.serverAddr;
      extraFlags = [
        "--flannel-backend=none"
        "--disable-network-policy"
        "--tls-san=100.126.30.73"
        "--tls-san=100.65.16.13"
        "--tls-san=100.80.37.112"
        "--kube-apiserver-arg default-not-ready-toleration-seconds=60"
        "--kube-apiserver-arg default-unreachable-toleration-seconds=60"
        "--kubelet-arg node-status-update-frequency=2s"
        # Image GC: age-based eviction (unused images dropped after a week) plus
        # tighter disk-pressure thresholds so a sweep starts well before the XFS
        # data volume (shared with etcd/rook) gets crowded.
        "--kubelet-arg image-minimum-gc-age=24h"
        "--kubelet-arg image-maximum-gc-age=168h"
        "--kubelet-arg image-gc-low-threshold=60"
        "--kubelet-arg image-gc-high-threshold=70"
      ]
      ++ cfg.extraFlags;
    };

    boot.kernelModules = [
      "rbd"
      "nbd"
      "ceph"
    ];

    # Old layout only: nodes with a dedicated raw Ceph partition (cephLoopback =
    # false) let rook claim the partition directly and drop this entirely.
    systemd.services.k3sloop = lib.mkIf cfg.cephLoopback {
      wantedBy = [ "local-fs.target" ];
      after = [ "large.mount" ];
      description = "loopback device that k3s rook uses";
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        RemainAfterExit = "yes";
        ExecStart = ''${pkgs.util-linux}/bin/losetup -f /large/disk.img'';
        # Detach the loop before /large is unmounted. After=large.mount makes
        # systemd stop us first at shutdown, so the backing file is still
        # reachable when losetup -d runs. Without this, systemd-shutdown's
        # sync(2) hangs on the dangling loop and the box only reboots via
        # SysRq + the hardware watchdog below.
        ExecStop = pkgs.writeShellScript "k3sloop-stop" ''
          ${pkgs.util-linux}/bin/losetup -j /large/disk.img \
            | ${pkgs.coreutils}/bin/cut -d: -f1 \
            | while read -r dev; do
                ${pkgs.util-linux}/bin/losetup -d "$dev" || true
              done
        '';
      };
    };

    # Safety net: if shutdown stalls (rook/containerd/ceph kernel-side hang),
    # arm the hardware watchdog so the box reboots without needing SysRq.
    systemd.settings.Manager.RebootWatchdogSec = "3min";

    # Persistence for k3s. On refactored nodes cfg.persistDir = "/data" (XFS);
    # elsewhere it stays "/large" (btrfs).
    environment.persistence.${cfg.persistDir} = {
      directories = [
        "/var/lib/rancher"
        "/var/lib/rook"
        "/etc/rancher"
      ];
    };
  };
}
