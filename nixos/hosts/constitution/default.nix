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

    # Hardware
    inputs.nixos-hardware.nixosModules.common-cpu-intel
    inputs.nixos-hardware.nixosModules.common-gpu-intel
    inputs.nixos-hardware.nixosModules.common-pc-laptop
    inputs.nixos-hardware.nixosModules.common-pc-laptop-ssd

    # Desktop environment
    ../../modules/desktop/full
  ];

  # Enable full desktop environment
  modules.desktop.full.enable = true;

  # Enable laptop power management
  modules.system.laptop.enable = true;

  hardware.cpu.intel.updateMicrocode = true;
  boot.kernelModules = [ "kvm-intel" ];

  networking.firewall.enable = lib.mkForce false;
}
