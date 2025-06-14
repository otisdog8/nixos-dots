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
  services.k3s.clusterInit = true;
  services.k3s.extraFlags = [
    "--bind-address=100.126.30.73"
    "--node-ip=100.126.30.73"
    "--advertise-address=100.126.30.73"
  ];

  services.nfs.server.enable = true;
  services.nfs.server.exports = ''
    /tmp 100.0.0.0/8(rw,nohide,insecure,no_subtree_check,all_squash)
  '';

}
