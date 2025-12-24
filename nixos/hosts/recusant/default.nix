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
    ];

    plymouth.enable = lib.mkForce false;
  };

  imports = [
    ./disks.nix
    ./garage.nix
    ./minecraft.nix
    ./media.nix
    ./secrets.nix
    ./backups.nix

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

  # NFS server for k8s storage
  services.nfs.server.enable = true;
  services.nfs.server.exports = ''
    /export/k8s  100.0.0.0/8(rw,nohide,insecure,no_subtree_check,all_squash)
  '';

  networking.firewall.allowedTCPPorts = [ 2049 ];

  # Prometheus node exporter
  services.prometheus.exporters.node.enable = true;
}
