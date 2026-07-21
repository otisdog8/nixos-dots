# K3s Kubernetes cluster configuration
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.system.k3s;

  # Kubelet image GC. imageMaximumGCAge is a KubeletConfiguration-only field —
  # it was never registered as a --kubelet-arg CLI flag, so it must come from a
  # config file (passed via --kubelet-arg config=). The disk-pressure thresholds
  # and min age could still be flags, but keeping all four here avoids mixing
  # mechanisms and dodges the deprecated-flag warnings. No featureGates entry:
  # ImageMaximumGCAge is GA and on by default as of k8s 1.34 (we run 1.35).
  # Graceful node shutdown: kubelet takes a logind delay-inhibitor and drains
  # pods in priority order before the box powers off — ordinary pods first (which
  # unmounts their CephFS CSI volumes while the Rook mons/OSDs are still up), then
  # system-node-critical pods (the OSDs/CSI plugins) in the final window. This is
  # what breaks the shutdown-hang deadlock where the kernel CephFS mount outlives
  # the OSD pods backing it. Kubelet clamps shutdownGracePeriod to logind's
  # InhibitDelayMaxSec, so that's raised to match below. GracefulNodeShutdown is
  # beta/default-on since k8s 1.21, so no featureGates entry is needed.
  gracePeriod = 60; # ceiling per shutdown; kubelet proceeds early once pods drain
  kubeletConfig = pkgs.writeText "k3s-kubelet-config.yaml" ''
    apiVersion: kubelet.config.k8s.io/v1beta1
    kind: KubeletConfiguration
    imageMinimumGCAge: "24h"
    imageMaximumGCAge: "168h"
    imageGCHighThresholdPercent: 70
    imageGCLowThresholdPercent: 60
    shutdownGracePeriod: "${toString gracePeriod}s"
    shutdownGracePeriodCriticalPods: "20s"
  '';
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
        2381 # k3s, etcd metrics: --etcd-expose-metrics binds the metrics listener here (Prometheus scrape)
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
        # SANs for the API server serving cert: all three server node IPs, so a
        # kubeconfig/join can validate against any of them. k3s auto-adds each
        # server's own node-ip too, but list them explicitly to keep this honest.
        "--tls-san=100.103.225.29" # carrack
        "--tls-san=100.126.30.73" # arquitens
        "--tls-san=100.65.16.13" # munificent
        # Fast failover: shorten how long a dead node stays Ready before its pods
        # are evicted. node-monitor-grace-period (~20s detection) must accompany
        # the low status-update-frequency — the frequency alone doesn't move
        # detection, which is lease-driven on the controller side. Detection
        # (~20s) + toleration (60s) ≈ 80s to reschedule off a lost node.
        "--kube-apiserver-arg default-not-ready-toleration-seconds=60"
        "--kube-apiserver-arg default-unreachable-toleration-seconds=60"
        "--kube-controller-manager-arg node-monitor-grace-period=20s"
        "--kubelet-arg node-status-update-frequency=2s"
        # Double the kubelet's default per-node pod ceiling (110 -> 220). Purely a
        # scheduling cap; the CIDR pod-network sizing is unaffected here since
        # flannel is disabled and Cilium owns IPAM.
        "--kubelet-arg max-pods=220"
        # Expose embedded-etcd metrics for Prometheus. Boolean flag: moves etcd's
        # listen-metrics-urls off loopback (http://127.0.0.1:2381) onto this node's
        # bind-address, so metrics are scrapable at http://<node-ip>:2381/metrics
        # (node-ip is the tailnet IP set per host in extraFlags). Server-only; set
        # on every server so each embedded-etcd member is scraped. Reached over the
        # trusted tailscale0 interface (2381 also listed in the firewall below).
        "--etcd-expose-metrics"
        # Image GC (thresholds + age-based eviction) lives in kubeletConfig above,
        # because imageMaximumGCAge is config-file-only. k3s ships no kubelet
        # config of its own, so pointing --config here is safe (flags still win
        # for any overlapping field).
        "--kubelet-arg config=${kubeletConfig}"
      ]
      ++ cfg.extraFlags;
    };

    boot.kernelModules = [
      "rbd"
      "nbd"
      "ceph"
    ];

    # The Micron 5300 write-cache udev rule moved to system/ceph-osd-disk.nix
    # (the module that owns those drives' whole stack).

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

    # Kubelet clamps its shutdownGracePeriod (set in kubeletConfig) to this, so
    # raise it to match — otherwise graceful node shutdown silently shrinks to
    # logind's 5s default and pods don't get drained before power-off.
    services.logind.settings.Login.InhibitDelayMaxSec = gracePeriod;

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
