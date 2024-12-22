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
  networking.hostName = "carrack";
  time.timeZone = "America/Los_Angeles";

  boot.supportedFilesystems = [ "btrfs" ];

  imports = [
    ./disks.nix
    ../mixins/k0s
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    inputs.nixos-hardware.nixosModules.common-gpu-amd
    inputs.nixos-hardware.nixosModules.common-pc
    inputs.nixos-hardware.nixosModules.common-pc-ssd
  ];
  boot.initrd.kernelModules = [ "amdgpu" ];
  services.xserver.videoDrivers = [ "amdgpu" ];
  services.k0s.spec.api.address = "100.103.225.29";
  services.k0s.spec.api.sans = [ "100.103.225.29" ];
  services.k0s.isLeader = false;
  services.k3s.serverAddr = "https://100.126.30.73:6443";
}
