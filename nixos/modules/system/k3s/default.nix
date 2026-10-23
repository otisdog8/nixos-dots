# K3s Kubernetes cluster configuration
{
  config,
  inputs,
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

  # Where svc:k8s forwards: this server's API, at its --bind-address (the
  # API listens nowhere else), and Traefik's and LLDAP's Services (homelab
  # pins both).
  bindFlag = lib.findFirst (lib.hasPrefix "--bind-address=") null cfg.extraFlags;
  apiAddress = lib.removePrefix "--bind-address=" bindFlag;
  traefikClusterIp = "10.43.243.178";
  lldapClusterIp = "10.43.6.245";
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
    ./nfs.nix
    ./rollout.nix
    # Live container migration (CRIU): inert unless liveMigration is set.
    inputs.lcm.nixosModules.default
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

    tailscaleServices = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Host the cluster's Tailscale Service, svc:k8s, on this server: the
        API and Traefik at one tailnet address whichever node is up. Needs
        this node to be a tagged device, and the Service defined and
        auto-approved for its tag in the tailnet policy.
      '';
    };

    liveMigration = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Let this node send and receive live migrations of running pods (uorux/live-container-migration):
        CRIU 4.3 on k3s's PATH, the `lcm` containerd runtime handler (pods opt in with
        runtimeClassName: lcm), and lcm-agent on port 7790. The agents' shared token is derived
        from the k3s server token. Enabling it restarts k3s once (containerd reads its runtime
        drop-ins at start); running pods are unaffected.
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
    assertions = [
      {
        assertion = !cfg.tailscaleServices || bindFlag != null;
        message = "modules.system.k3s.tailscaleServices: svc:k8s forwards 6443 to the API's --bind-address, and extraFlags sets none.";
      }
    ];

    # Keep cluster nodes on the explicitly selected kernel series instead of
    # following the fleet-wide linuxPackages_latest default.
    boot.kernelPackages = lib.mkOverride 90 pkgs.linuxPackages_7_2;

    # Cilium's VXLAN between nodes rides tailscale0, so every cross-node pod
    # packet waits in the tun's ring until tailscaled reads it. The ring is
    # txqueuelen long (500 by default, and tailscaled leaves it so); a full
    # one drops (tx_dropped), and bursts of tens of thousands a minute cost
    # DNS lookups and LDAP binds (2026-10-19). Writing it resizes the live
    # ring, so this applies whenever tailscaled makes the device.
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="tailscale0", ATTR{tx_queue_len}="10000"
    '';

    # Cilium carries the sending pod's security identity in the top 16 bits
    # of the packet mark, and the mark survives into the VXLAN packet's route
    # lookup. Tailscale's rules (5210-5250) send any mark with 0x08 in bits
    # 16-23 (its own "bypass" bit, 0x80000/0xff0000) to the main table, which
    # routes a peer's tailnet IP out the LAN, where it is lost. So every pod
    # whose identity's low byte is 0x08 (1 in 256) lost all cross-node
    # traffic: cnpg/postgres-2 (identity 9992 = 0x2708, mark 0x27080400) on
    # 2026-10-22. These rules give such packets table 52 first, like every
    # other pod's. Cilium's mark nibbles (bits 8-11) that carry an identity:
    # 0x4 overlay, 0xa/0xb proxy, 0xf identity. Tailscale's own packets have
    # that nibble clear, so they still bypass.
    systemd.services.cilium-tailscale-mark-rules = {
      description = "Route Cilium identity-marked packets via Tailscale's table";
      wantedBy = [ "multi-user.target" ];
      before = [ "k3s.service" ];
      path = [ pkgs.iproute2 ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        for m in 0x80400 0x80a00 0x80b00 0x80f00; do
          ip rule del priority 5200 fwmark "$m/0xff0f00" lookup 52 2>/dev/null || true
          ip rule add priority 5200 fwmark "$m/0xff0f00" lookup 52
        done
      '';
      preStop = ''
        for m in 0x80400 0x80a00 0x80b00 0x80f00; do
          ip rule del priority 5200 fwmark "$m/0xff0f00" lookup 52 2>/dev/null || true
        done
      '';
    };

    # The node's firewall: the tailnet and Cilium's own interfaces are
    # trusted; the LAN NIC gets only what LAN hosts use. Traffic for the
    # LAN address (10.0.0.200) and NodePorts never reaches it: Cilium's BPF
    # on the NIC handles those first. What the LAN still reaches here: SSH,
    # Tailscale's direct-path UDP and netconsole senders' UDP 6666 (each
    # module opens its own), ICMP.
    networking.firewall = {
      enable = true;
      trustedInterfaces = [
        "tailscale0" # networking.nix's, repeated: this list is what matters here
        "cilium_host" # the host's side of the pod network
        "cilium_net"
        "cilium_vxlan" # pod traffic from the other nodes
        "lxc+" # this node's pods (kubelet probes' replies, pods to the host)
      ];
    };
    # Cluster ports, on the tailnet only (trusted already: documentation and
    # a safety net). Global allowedTCPPorts would open them on the LAN too.
    networking.firewall.interfaces.tailscale0 = {
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
        8472 # Cilium VXLAN between the nodes
        51871 # Cilium WireGuard (if encryption is ever turned on)
      ];
    };

    # Every cluster node is both a netconsole sender and a collector (vector ->
    # VictoriaLogs via the local NodePort): these are exactly the hosts whose
    # panics take workloads down, and with all three collecting, each node can
    # target a collector that isn't itself — so no node's crash goes missing.
    # (arquitens overrides the default target, itself, to carrack in its host
    # config; a module assertion catches send-to-self.)
    modules.system.netconsole = {
      enable = lib.mkDefault true;
      collector.enable = lib.mkDefault true;
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
        # No ServiceLB (klipper): Cilium's LB IPAM and L2 announcements give
        # Traefik its LAN address (homelab: apps/infra/cilium-lb), and the
        # tailnet reaches it through svc:k8s below. Off, nothing listens on
        # the nodes' own 80/443 any more. Every server needs it.
        "--disable=servicelb"
        # SANs for the API server serving cert: all three server node IPs, so a
        # kubeconfig/join can validate against any of them. k3s auto-adds each
        # server's own node-ip too, but list them explicitly to keep this honest.
        "--tls-san=100.103.225.29" # carrack
        "--tls-san=100.126.30.73" # arquitens
        "--tls-san=100.65.16.13" # munificent
        # svc:k8s's API name (*.k8s.rooty.dev is its tailnet address).
        "--tls-san=api.k8s.rooty.dev"
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

    # svc:k8s, the tailnet's way in whichever node is up: one Tailscale
    # Service, one tailnet address, which *.k8s.rooty.dev resolves to.
    # Plain tcp forwarding, so TLS is end to end (k3s's and Traefik's own
    # certificates, never one Tailscale terminates).
    #  - 6443: this server's own API. Not the kubernetes Service: tailscaled
    #    marks its own connections to skip Tailscale's routes, so it can't
    #    reach another server's tailnet address, and two of three tries
    #    failed (2026-10-18). Clients use api.k8s.rooty.dev, a SAN below.
    #  - 443, 80: Traefik's Service. It outlives ServiceLB.
    #  - 6360: LLDAP's LDAPS, as ldap.k8s.rooty.dev (its cert has
    #    *.k8s.rooty.dev). For recusant's Jellyfin; the tailnet policy
    #    grants this port to recusant alone. Plain LDAP (3890) isn't
    #    forwarded.
    # Tailscale fails over only when a host goes offline, not when what's
    # behind it fails, so the node stops taking new connections while its
    # k3s is down (tailscale-serve is bound to k3s, below).
    services.tailscale.serve = lib.mkIf cfg.tailscaleServices {
      enable = true;
      services.k8s.endpoints = {
        "tcp:6443" = "tcp://${apiAddress}:6443";
        "tcp:443" = "tcp://${traefikClusterIp}:443";
        "tcp:80" = "tcp://${traefikClusterIp}:80";
        "tcp:6360" = "tcp://${lldapClusterIp}:6360";
      };
    };
    # The serve config only applies once tailscaled is logged in; at boot
    # it's often not yet ("unexpected state: NoState", 2026-10-18), and the
    # unit ran once. Wait for Running, and retry past a slow login. Bound to
    # k3s: started with it, and drained (no new connections; open ones
    # finish) when it stops, so Tailscale sends clients to another host.
    systemd.services.tailscale-serve = lib.mkIf cfg.tailscaleServices {
      bindsTo = [ "k3s.service" ];
      after = [ "k3s.service" ];
      wantedBy = [ "k3s.service" ];
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        ExecStop = "${lib.getExe config.services.tailscale.package} serve drain svc:k8s";
        ExecStartPre = pkgs.writeShellScript "tailscale-serve-wait" ''
          for _ in $(seq 60); do
            ${lib.getExe config.services.tailscale.package} status --json 2>/dev/null \
              | ${lib.getExe pkgs.jq} -e '.BackendState == "Running"' >/dev/null && exit 0
            sleep 2
          done
          echo "tailscaled not Running after 120s" >&2
          exit 1
        '';
        Restart = "on-failure";
        RestartSec = 15;
      };
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
        ExecStart = "${pkgs.util-linux}/bin/losetup -f /large/disk.img";
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
      ]
      # Fences (pods that must never restart here) and restore tombstones must survive reboots;
      # the image staging under it is tmpfs regardless.
      ++ lib.optional cfg.liveMigration "/var/lib/lcm";
    };

    services.lcm = {
      enable = cfg.liveMigration;
      # Ship lcm-agent/lcm-runc logs to the same VictoriaLogs endpoint (its ClusterIP) the
      # netconsole collector on every cluster node uses; query `unit:lcm-agent host:<node>`.
      # The agent port (7790) needs no firewall entry: peers use the tailnet IPs (tailscale0 is
      # trusted) and pods come in on lxc+ (trusted too); the LAN can't reach it.
      logShipping.victoriaLogsUrl = lib.mkDefault config.modules.system.netconsole.collector.victoriaLogsUrl;
    };
  };
}
