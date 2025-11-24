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
  networking.hostName = "galaxy";
  time.timeZone = "America/Los_Angeles";

  boot.supportedFilesystems = [ "btrfs" ];

  imports = [
    ./disks.nix
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    inputs.nixos-hardware.nixosModules.common-pc
    inputs.nixos-hardware.nixosModules.common-pc-ssd
    ../modules/apps/obsidian.nix
  ];

  # Enable Obsidian via new modular system
  modules.apps.obsidian = {
    enable = true;
    sandbox.enable = true;
    # Bind vault directory for Obsidian access
    sandbox.extraBinds = [ "Documents/obsidian" ];
  };

  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia.open = true;
  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.beta;
  hardware.nvidia.modesetting.enable = true;
}
