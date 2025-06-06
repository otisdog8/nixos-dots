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
    ../mixins/k3s
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    inputs.nixos-hardware.nixosModules.common-gpu-amd
    inputs.nixos-hardware.nixosModules.common-pc
    inputs.nixos-hardware.nixosModules.common-pc-ssd
  ];
  boot.initrd = {
    supportedFilesystems = [ "nfs" ];
    kernelModules = [
      "nfs"
      "amdgpu"
    ];
  };
  services.xserver.videoDrivers = [ "amdgpu" ];
  services.k3s.serverAddr = "https://100.126.30.73:6443";
  services.k3s.extraFlags = [
    "--bind-address=100.103.225.29"
    "--node-ip=100.103.225.29"
    "--advertise-address=100.103.225.29"
  ];
}
