# The sensitive cluster's k3s: a second cluster, one server per machine, in
# the VM beside each main node (hosts/<machine>-sensitive). The rule it
# keeps: it may call into the main cluster, but the main cluster never
# administers it, terminates its TLS, issues its certificates or signs
# anyone into it. So nothing here is shared with modules/system/k3s, which
# is the main cluster's (svc:k8s, Ceph, lcm, node-rollout): a few generic
# pieces are repeated instead, so a change for one cluster never rebuilds
# the other's nodes.
#
# Its own token (sops, encrypted to the sensitive guests and Jacob only), its
# own CIDRs (10.52/16 pods, 10.53/16 Services: nothing to mix up with main's
# 10.42/10.43, and no tailnet subnet routes either way), Cilium VXLAN over
# the tailnet like main's start. No hostd, no agent VM, no journal shipping
# to main's VictoriaLogs (hosts/sensitive-common.nix).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.system.k3sSensitive;

  gracePeriod = 60;
  # Traefik's Service, pinned in homelab-sensitive (infra/traefik).
  traefikClusterIp = "10.53.0.80";
  tailscale = lib.getExe config.services.tailscale.package;
  kubeletConfig = pkgs.writeText "k3s-sensitive-kubelet-config.yaml" ''
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
  options.modules.system.k3sSensitive = {
    enable = lib.mkEnableOption "a server of the sensitive k3s cluster";

    clusterInit = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Start a new cluster (the first server only, once).";
    };

    serverAddr = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://100.64.0.1:6443";
      description = "A running server's API to join (every server but the first).";
    };

    nodeIp = lib.mkOption {
      type = lib.types.str;
      description = ''
        This guest's tailnet address: k3s binds, advertises and talks to the
        other servers only there. Known after the guest's first Tailscale
        login (hosts/sensitive-common.nix).
      '';
    };

    serverIps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Every server's tailnet address, for the API certificate's SANs.";
    };

    tokenSopsFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        The cluster token, sops-encrypted to the sensitive guests' host keys
        and Jacob's age key: never to a main node or recusant.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.clusterInit != (cfg.serverAddr != null);
        message = "modules.system.k3sSensitive: exactly one of clusterInit and serverAddr.";
      }
    ];

    # Piraeus (LINSTOR) replicates volumes with DRBD 9, which the guest's
    # kernel needs as a module of its own build: Piraeus's module loader
    # can't compile one on NixOS (homelab-sensitive removes it). Its
    # storage pool is an LVM thin pool, so device-mapper's thin target too,
    # loaded here: the satellite has no /lib/modules to load it from.
    boot.extraModulePackages = [ config.boot.kernelPackages.drbd ];
    boot.kernelModules = [
      "drbd"
      "drbd_transport_tcp"
      "dm_thin_pool"
    ];
    boot.extraModprobeConfig = ''
      options drbd usermode_helper=disabled
    '';

    # The guest's own LVM looks at no device: the one LVM disk here is
    # LINSTOR's (hosts/sensitive-disks.nix), and only the satellite's LVM,
    # with its own configuration, manages it. Two LVMs activating the same
    # VG, or this one scanning the DRBD devices built on it, is what Piraeus
    # warns about; scanning nothing rules out both.
    environment.etc."lvm/lvm.conf".text = ''
      devices/global_filter = [ "r|.*|" ]
    '';

    # As modules/system/k3s: Cilium's VXLAN rides tailscale0, whose 500-packet
    # ring overflowed in bursts.
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="tailscale0", ATTR{tx_queue_len}="10000"
    '';

    # As modules/system/k3s (rule 5200 only: no native routing here). A pod
    # whose Cilium identity has 0x08 in its low byte carries Tailscale's
    # bypass bit in its packet mark, and its VXLAN packets would leave by the
    # LAN; these send them to Tailscale's table like every other pod's.
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

    # Not the fleet's trusted tailscale0 (networking.nix): the tailnet
    # policy decides which peers reach a sensitive guest, and this decides
    # which ports exist at all, so a policy mistake opens nothing that isn't
    # listed here. Cilium's own interfaces stay trusted. The LAN gets
    # nothing but Tailscale's direct-path UDP (remote-access.nix).
    networking.firewall = {
      enable = true;
      # mkForce replaces every definition, nixpkgs' own [ "lo" ] too: list it,
      # or the API server can't reach etcd on 127.0.0.1:2379 (2026-10-25).
      trustedInterfaces = lib.mkForce [
        "lo"
        "cilium_host"
        "cilium_net"
        "cilium_vxlan"
        "lxc+"
      ];
      # Global TCP ports would be open on the LAN: none (remote-access.nix's
      # 22 included; ssh is on the tailnet below).
      allowedTCPPorts = lib.mkForce [ ];
      interfaces.tailscale0 = {
        allowedTCPPorts = [
          22 # ssh, Jacob's devices only (tailnet policy)
          6443 # API server: the other servers, pods, kubectl
          2379 # etcd clients
          2380 # etcd peers
          10250 # kubelet: logs, exec, metrics from the API server
          4240 # cilium-health
          4244 # Hubble server
          9100 # node-exporter (the in-cluster DaemonSet, host network)
          9962 # Cilium agent metrics
          9963 # Cilium operator metrics
          2381 # etcd metrics (--etcd-expose-metrics)
        ];
        # Nothing for LINSTOR or DRBD: the satellites, and DRBD's
        # replication with them, are on the pod network (Cilium's VXLAN
        # below), where the cluster's network policy decides who reaches
        # them.
        allowedUDPPorts = [
          8472 # Cilium VXLAN between the servers
        ];
      };
    };

    environment.systemPackages = with pkgs; [
      k3s
      # The guest has no nix to fetch tools with (the store is the machine's,
      # read-only).
      conntrack-tools
      ethtool
      strace
      lsof
      sysstat
    ];

    sops.secrets.k3s-sensitive-token = {
      sopsFile = cfg.tokenSopsFile;
      key = "token";
      # A changed token must not restart k3s by itself.
    };

    services.k3s = {
      enable = true;
      role = "server";
      inherit (cfg) clusterInit;
      serverAddr = lib.mkIf (cfg.serverAddr != null) cfg.serverAddr;
      tokenFile = config.sops.secrets.k3s-sensitive-token.path;
      extraFlags = [
        "--bind-address=${cfg.nodeIp}"
        "--node-ip=${cfg.nodeIp}"
        "--advertise-address=${cfg.nodeIp}"
        "--cluster-cidr=10.52.0.0/16"
        "--service-cidr=10.53.0.0/16"
        "--cluster-dns=10.53.0.10"
        # Cilium (installed by Flux) is the CNI and the network policy.
        "--flannel-backend=none"
        "--disable-network-policy"
        # Traefik comes from the cluster's repo, digest-pinned, on the
        # tailnet entrypoints; no ServiceLB either.
        "--disable=traefik"
        "--disable=servicelb"
        # Secrets in etcd encrypted (and so in its snapshots).
        "--secrets-encryption"
        # etcd's metrics on the node's address too, :2381 (plain HTTP,
        # read-only), for the cluster's vmagent.
        "--etcd-expose-metrics"
        "--tls-san=api.s.rooty.dev"
        "--kube-apiserver-arg default-not-ready-toleration-seconds=60"
        "--kube-apiserver-arg default-unreachable-toleration-seconds=60"
        "--kube-controller-manager-arg node-monitor-grace-period=20s"
        "--kubelet-arg node-status-update-frequency=2s"
        "--kubelet-arg config=${kubeletConfig}"
        # Images from the other servers first (Spegel): an image pulled once
        # isn't fetched from the internet again by the next node.
        "--embedded-registry"
      ]
      ++ map (ip: "--tls-san=${ip}") cfg.serverIps;
    };

    # svc:sensitive, the tailnet's way in whichever server is up: one
    # Tailscale Service, one tailnet address, which *.s.rooty.dev resolves
    # to. Plain tcp forwarding, TLS end to end (Traefik's and k3s's own
    # certificates; Tailscale terminates nothing). The tailnet policy grants
    # its ports separately:
    #  - 443: Traefik's websecure entrypoint, the APIs (broker, LiteLLM).
    #  - 8443: Traefik's admin entrypoint: panels, Authelia, Grafana.
    #  - 6443: this server's own API, as api.s.rooty.dev (a SAN above). Not
    #    the kubernetes Service: tailscaled's own connections skip
    #    Tailscale's routes, so it couldn't reach another server's tailnet
    #    address (modules/system/k3s, 2026-10-18).
    # tailscaled answers the service's address itself and dials these from
    # the host, so nothing listens on the guest's own 443/8443 and the
    # firewall above opens neither.
    services.tailscale.serve = {
      enable = true;
      services.sensitive.endpoints = {
        "tcp:443" = "tcp://${traefikClusterIp}:443";
        "tcp:8443" = "tcp://${traefikClusterIp}:8443";
        "tcp:6443" = "tcp://${cfg.nodeIp}:6443";
      };
    };
    # As modules/system/k3s: wait for tailscaled to be logged in, then for
    # Traefik's ClusterIP to answer from here (k3s counts as started long
    # before Cilium routes ClusterIPs), and only then advertise. Bound to
    # k3s, and drained when it stops: open connections finish, new ones go
    # to the other servers.
    systemd.services.tailscale-serve = {
      bindsTo = [ "k3s.service" ];
      after = [ "k3s.service" ];
      wantedBy = [ "k3s.service" ];
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        ExecStop = "${tailscale} serve drain svc:sensitive";
        ExecStartPre = pkgs.writeShellScript "tailscale-serve-wait" ''
          running=
          for _ in $(seq 60); do
            if ${tailscale} status --json 2>/dev/null \
              | ${lib.getExe pkgs.jq} -e '.BackendState == "Running"' >/dev/null; then
              running=1
              break
            fi
            sleep 2
          done
          [ -n "$running" ] || { echo "tailscaled not Running after 120s" >&2; exit 1; }
          for _ in $(seq 300); do
            ${pkgs.coreutils}/bin/timeout 3 ${pkgs.bash}/bin/bash -c ': </dev/tcp/${traefikClusterIp}/443' 2>/dev/null && exit 0
            sleep 2
          done
          echo "Traefik's ClusterIP (${traefikClusterIp}:443) doesn't answer from here after 10 min" >&2
          exit 1
        '';
        Restart = "on-failure";
        RestartSec = 15;
      };
    };

    # As modules/system/k3s: the API binds the tailnet address, which isn't
    # there until tailscaled has logged in; wait for it, and keep retrying.
    systemd.services.k3s = {
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig.ExecStartPre = [
        (pkgs.writeShellScript "k3s-wait-bind-address" ''
          for _ in $(seq 300); do
            ${pkgs.iproute2}/bin/ip -o addr show | ${pkgs.gnugrep}/bin/grep -qF " ${cfg.nodeIp}/" && exit 0
            sleep 1
          done
          echo "${cfg.nodeIp} is on no interface after 300 s" >&2
          exit 1
        '')
      ];
    };

    # Spegel's registry mirror for every registry: `--embedded-registry`
    # serves only what registries.yaml lists.
    environment.etc."rancher/k3s/registries.yaml".text = ''
      mirrors:
        "*":
    '';

    # Kubelet's graceful shutdown is clamped to logind's delay.
    services.logind.settings.Login.InhibitDelayMaxSec = gracePeriod;
    systemd.settings.Manager.RebootWatchdogSec = "3min";

    # etcd, containerd's images, the local PVs; and the node's password
    # (/etc/rancher/node), which the servers check every time it joins: a
    # new one each boot (the root is wiped) and they'd refuse the node as a
    # duplicate. The rest of /etc/rancher is k3s's kubeconfig, rewritten at
    # every start, and registries.yaml from this module.
    #
    # LVM's metadata backups and archive of LINSTOR's VG: the satellite
    # keeps them here rather than in /etc/lvm (homelab-sensitive,
    # infra/storage), for recovering the VG's metadata by hand.
    environment.persistence."/data".directories = [
      "/var/lib/rancher"
      "/etc/rancher/node"
      "/var/lib/linstor-lvm"
    ];
  };
}
