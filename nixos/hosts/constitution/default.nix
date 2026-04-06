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

    # System modules
    ../../modules/system/hardware/intel.nix

    # Desktop environment
    ../../modules/desktop/full

    # Gaming bundle
    ../../modules/bundles/gaming.nix
  ];

  # Enable full desktop environment
  modules.desktop.full.enable = true;

  # Enable gaming bundle
  modules.bundles.gaming.enable = true;

  # Enable laptop power management
  modules.system.laptop.enable = true;

  hardware.cpu.intel.updateMicrocode = true;
  boot.kernelModules = [ "kvm-intel" ];

  # Enable Intel iGPU (VA-API hardware video encode/decode)
  modules.system.hardware.intel = {
    enable = true;
    enableCompute = true;
  };

  networking.firewall.enable = lib.mkForce false;
}
