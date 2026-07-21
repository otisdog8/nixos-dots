{
  hostname,
  inputs,
  lib,
  pkgs,
  username,
  config,
  ...
}:
{
  networking.hostName = "recusant";
  time.timeZone = "America/Los_Angeles";

  boot = {
    supportedFilesystems = [
      "btrfs"
      "bcachefs"
    ];
    initrd = {
      availableKernelModules = [
        "tpm_crb"
        "tpm_tis"
      ];
      clevis = {
        enable = true;
        devices."${config.fileSystems."/mnt/bcachefs".device}".secretFile = /persist/secret.jwe;
      };
    };

    kernelParams = [
      "nvme_core.default_ps_max_latency_us=0"
      "pcie_aspm=off"
      "pcie_port_pm=off"
      #"usb-storage.quirks=2ce5:0014:u" # Disable UAS for AKiTiO NT2 enclosures
    ];

    plymouth.enable = lib.mkForce false;
  };

  imports = [
    inputs.disko.nixosModules.disko
    inputs.sops-nix.nixosModules.sops
    ./disks.nix
    ./garage.nix
    ./attic.nix
    ./minecraft.nix
    ./media.nix
    ./secrets.nix
    ./backups.nix
    ./ddns.nix
    ./agent-auth.nix
    ./hindsight.nix
    ./hermes-homelab-recusant.nix
    ./hermes-a2a.nix

    # Hardware
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    inputs.nixos-hardware.nixosModules.common-pc
    inputs.nixos-hardware.nixosModules.common-pc-ssd

    # System modules
    ../../modules/system/hardware/intel.nix

    # Desktop environment
    ../../modules/desktop/full
  ];

  # Host-wide sops-nix base config; per-secret declarations live next to their
  # consumers (minecraft.nix, ddns.nix, attic.nix, agent-auth.nix, ...).
  sops = {
    defaultSopsFile = ./secrets/recusant.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  };

  # Enable full desktop environment
  modules.desktop.full.enable = true;

  # Enable Intel iGPU (for media transcoding)
  modules.system.hardware.intel = {
    enable = true;
    enableCompute = true;
  };

  # Enable system hardening baseline (server profile).
  # No Bluetooth on this host, so af_alg can go too.
  modules.system.hardening = {
    enable = true;
    profile = "server";
    blacklistAfAlg = true;
  };

  # Compressed swap (zswap), matching arquitens/carrack/munificent. Backing swap
  # is the randomEncryption partition in disks.nix (encrypted per-boot, so no
  # LUKS-LV needed here — zswap tiers cold pages onto it fine). See
  # modules/system/zswap.nix for the RAM-side tuning.
  #
  # protectedSlices = [] (unlike the k3s nodes): recusant has no latency-sensitive
  # etcd path to shield, and every real workload (garage, minecraft, media,
  # agent-auth, …) runs in system.slice. Leaving the default ["system.slice"]
  # would disable disk writeback for all of them, so cold pages could never tier
  # to backing swap — defeating the point. Let everything tier normally.
  modules.system.zswap = {
    enable = true;
    protectedSlices = [ ];
  };

  # Post-unlock PCR 15 verification for TPM2 LUKS unlock.
  # Bootstrap pass: measurement only, no enforcement. After a known-good boot,
  # capture with `sudo systemd-analyze pcrs 15 --json=short`, paste the sha256
  # into expectedPcr15, rebuild, and reboot.
  modules.system.pcr-verification = {
    enable = true;
    # New drive = new LUKS mapper name (see disks.nix) so disko can format it live.
    deviceName = "cryptrecusant";
    # STALE after the drive swap: PCR15 is measured off the new LUKS volume, so
    # this hash won't match on the migrated drive. After re-enrolling TPM2 on the
    # new LUKS and a known-good boot, recapture with
    #   sudo systemd-analyze pcrs 15 --json=short
    # and paste the new sha256 here, then rebuild.
    expectedPcr15 = "b4074ce9edb24552602ca6dd4eb01d8b74d1a374ca3945795e2403d56dabab44";
  };

  # NFS server for k8s storage. Export and firewall both pin to the tailnet
  # (the global trustedInterfaces = [ "tailscale0" ] makes 2049 belt-and-
  # suspenders, but keep it declared for clarity).
  services.nfs.server.enable = true;
  # Scope to Tailscale's CGNAT range (100.64.0.0/10), not 100.0.0.0/8 — /8 also
  # covers public 100.0.0.0–100.63.255.255, so a spoofed/off-tailnet source in that
  # band would match. Tighten further to exact node IPs if the k8s node set is
  # stable. Export is a dedicated dir (/export/k8s), never a system path.
  services.nfs.server.exports = ''
    /export/k8s  100.64.0.0/10(rw,nohide,insecure,no_subtree_check,all_squash)
  '';
  networking.firewall.allowedTCPPorts = [ 2049 ];

  # Prometheus exporters
  services.prometheus.exporters.node = {
    enable = true;
    # bcachefs collector is default-enabled in node_exporter 1.11.1; listed
    # explicitly to document intent. Reads /sys/fs/bcachefs (root-only files),
    # which works since the exporter runs as root (DynamicUser = false).
    # systemd:    per-unit state (failed/active) across all units.
    # processes:  aggregate process/thread counts by state.
    # interrupts/softirqs: per-CPU IRQ/softirq counts — spot IRQ storms.
    # ethtool:    NIC driver stats (drops/errors/ring).
    # qdisc:      network queueing-discipline stats (needs AF_NETLINK).
    # tcpstat:    TCP socket-state counts from /proc/net/tcp.
    # (PSI `pressure` collector is on by default → node_pressure_{cpu,memory,io}_*.)
    enabledCollectors = [
      "bcachefs"
      "systemd"
      "processes"
      "interrupts"
      "softirqs"
      "ethtool"
      "qdisc"
      "tcpstat"
    ];
  };

  # Keep the exporter scrapeable when the host is under memory/CPU/IO pressure —
  # exactly when its metrics matter most. The module already sets Restart=always;
  # this adds OOM protection + scheduling priority + a cgroup memory floor.
  # (RestrictRealtime=true is hard-set by the module, so use Nice + best-effort
  # IO rather than a realtime class.)
  systemd.services.prometheus-node-exporter.serviceConfig = {
    OOMScoreAdjust = -900; # kernel OOM-killer avoids it
    Nice = -5; # CPU priority under load
    IOSchedulingClass = "best-effort";
    IOSchedulingPriority = 0; # disk collectors don't stall behind IO pressure
    MemoryLow = "48M"; # cgroup reclaim floor so it isn't evicted
  };
  services.prometheus.exporters.smartctl = {
    enable = true;
    devices = [ ];
    maxInterval = "5m"; # Cache results for 5 minutes (13 devices = slow cold scrapes)
  };

  # Give disk group access to NVMe controller devices for smartctl
  services.udev.extraRules = ''
    SUBSYSTEM=="nvme", KERNEL=="nvme[0-9]*", GROUP="disk", MODE="0660"
  '';
}
