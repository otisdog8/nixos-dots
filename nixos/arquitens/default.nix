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
  networking.hostName = "arquitens";
  time.timeZone = "America/Los_Angeles";

  boot.supportedFilesystems = [ "btrfs" ];

  imports = [
    ./disks.nix

    # Hardware
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    inputs.nixos-hardware.nixosModules.common-gpu-amd
    inputs.nixos-hardware.nixosModules.common-pc
    inputs.nixos-hardware.nixosModules.common-pc-ssd

    # System modules
    ../modules/system/hardware/amd.nix
    ../modules/system/k3s
  ];

  boot.initrd.supportedFilesystems = [ "nfs" ];
  boot.initrd.kernelModules = [ "nfs" ];

  # Enable AMD GPU
  modules.system.hardware.amd.enable = true;

  # K3s cluster init node (primary)
  modules.system.k3s = {
    enable = true;
    clusterInit = true;
    extraFlags = [
      "--bind-address=100.126.30.73"
      "--node-ip=100.126.30.73"
      "--advertise-address=100.126.30.73"
    ];
  };

  # NFS server
  services.nfs.server.enable = true;
  services.nfs.server.exports = ''
    /tmp 100.0.0.0/8(rw,nohide,insecure,no_subtree_check,all_squash)
  '';
}
