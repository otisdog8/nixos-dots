{
  hostname,
  inputs,
  lib,
  pkgs,
  username,
  ...
}:
{
  networking.hostName = "constitution";
  time.timeZone = "America/Los_Angeles";

  boot.supportedFilesystems = [ "btrfs" ];

  imports = [
    ./disks.nix
    ./secrets.nix
    ./backups.nix
    inputs.nixos-hardware.nixosModules.common-cpu-intel
    inputs.nixos-hardware.nixosModules.common-gpu-intel
    inputs.nixos-hardware.nixosModules.common-pc-laptop
    inputs.nixos-hardware.nixosModules.common-pc-laptop-ssd
  ];

  hardware.cpu.intel.updateMicrocode = true;
  boot.kernelModules = [ "kvm-intel" ];
networking.firewall.enable = lib.mkForce false;
}
