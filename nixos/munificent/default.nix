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
  networking.hostName = "munificent";
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

  # K3s cluster node
  modules.system.k3s = {
    enable = true;
    serverAddr = "https://100.126.30.73:6443";
    extraFlags = [
      "--bind-address=100.65.16.13"
      "--node-ip=100.65.16.13"
      "--advertise-address=100.65.16.13"
    ];
  };
}
