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

  boot.supportedFilesystems = [ "btrfs" ];

  imports = [
    ./disks.nix
    ./minecraft.nix
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    inputs.nixos-hardware.nixosModules.common-pc
    inputs.nixos-hardware.nixosModules.common-pc-ssd
  ];

  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia.open = false;
  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.beta;
  hardware.nvidia.modesetting.enable = true;

  services.nfs.server.enable = true;
  services.nfs.server.exports = ''
    /export/k8s  100.126.30.73(rw,nohide,insecure,no_subtree_check,all_squash) 100.103.225.29(rw,nohide,insecure,no_subtree_check,all_squash) 100.65.16.13(rw,nohide,insecure,no_subtree_check,all_squash)
  '';

  networking.firewall.allowedTCPPorts = [ 2049 ];
}
