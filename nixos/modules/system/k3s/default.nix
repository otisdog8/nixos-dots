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
  };

  config = lib.mkIf cfg.enable {
    # Kubernetes requires swap to be disabled
    swapDevices = lib.mkForce [ ];

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

      enable = lib.mkForce false;
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
      ]
      ++ cfg.extraFlags;
    };

    boot.kernelModules = [
      "rbd"
      "nbd"
      "ceph"
    ];

    systemd.services.k3sloop = {
      wantedBy = [ "local-fs.target" ];
      after = [ "large.mount" ];
      description = "loopback device that k3s rook uses";
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        ExecStart = ''${pkgs.util-linux}/bin/losetup -f /large/disk.img'';
        RemainAfterExit = "yes";
      };
    };

    # Persistence for k3s
    environment.persistence."/large" = {
      directories = [
        "/var/lib/rancher"
        "/var/lib/rook"
        "/etc/rancher"
      ];
    };
  };
}
