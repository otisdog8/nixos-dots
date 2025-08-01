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

  boot.supportedFilesystems = [
    "btrfs"
    "bcachefs"
  ];
  boot.initrd.availableKernelModules = [
    "tpm_crb"
    "tpm_tis"
  ];

  boot.kernelParams = [
    "nvme_core.default_ps_max_latency_us=0"
    "pcie_aspm=off"
    "pcie_port_pm=off"
  ];

  boot.plymouth.enable = lib.mkForce false;

  boot.initrd.clevis = {
    enable = true;
    devices."${config.fileSystems."/mnt/bcachefs".device}".secretFile = /persist/secret.jwe;
  };

  imports = [
    ./disks.nix
    ./minecraft.nix
    ./media.nix
    ./secrets.nix
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    inputs.nixos-hardware.nixosModules.common-pc
    inputs.nixos-hardware.nixosModules.common-pc-ssd
  ];

  services.xserver.videoDrivers = [ "modesetting" ];
  hardware.graphics.extraPackages32 = with pkgs.pkgsi686Linux; [ intel-media-driver ];
  hardware.graphics = {
    # hardware.graphics since NixOS 24.11
    enable = true;
    extraPackages = with pkgs; [
      libvdpau-va-gl
      intel-media-driver
      intel-compute-runtime
      vpl-gpu-rt # for newer GPUs on NixOS >24.05 or unstable
      intel-vaapi-driver # previously vaapiIntel
      vaapiVdpau
    ];
  };

  services.nfs.server.enable = true;
  services.nfs.server.exports = ''
    /export/k8s  100.0.0.0/8(rw,nohide,insecure,no_subtree_check,all_squash)
  '';

  networking.firewall.allowedTCPPorts = [ 2049 ];
}
