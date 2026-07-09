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

  # Post-unlock PCR 15 verification for TPM2 LUKS unlock.
  # Bootstrap pass: measurement only, no enforcement. After a known-good boot,
  # capture with `sudo systemd-analyze pcrs 15 --json=short`, paste the sha256
  # into expectedPcr15, rebuild, and reboot.
  modules.system.pcr-verification = {
    enable = true;
    expectedPcr15 = "b4074ce9edb24552602ca6dd4eb01d8b74d1a374ca3945795e2403d56dabab44";
  };

  # NFS server for k8s storage. Export and firewall both pin to the tailnet
  # (the global trustedInterfaces = [ "tailscale0" ] makes 2049 belt-and-
  # suspenders, but keep it declared for clarity).
  services.nfs.server.enable = true;
  services.nfs.server.exports = ''
    /export/k8s  100.0.0.0/8(rw,nohide,insecure,no_subtree_check,all_squash)
  '';
  networking.firewall.allowedTCPPorts = [ 2049 ];

  # Prometheus exporters
  services.prometheus.exporters.node = {
    enable = true;
    # bcachefs collector is default-enabled in node_exporter 1.11.1; listed
    # explicitly to document intent. Reads /sys/fs/bcachefs (root-only files),
    # which works since the exporter runs as root (DynamicUser = false).
    # systemd: per-unit state (failed/active) across all units.
    # processes: aggregate process/thread counts by state.
    enabledCollectors = [ "bcachefs" "systemd" "processes" ];
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
