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
  boot.blacklistedKernelModules = [ "amdgpu" ];

  imports = [
    ./disks.nix

    # Hardware
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    inputs.nixos-hardware.nixosModules.common-pc
    inputs.nixos-hardware.nixosModules.common-pc-ssd

    # Desktop environment
    ../../modules/desktop/full

    # Gaming bundle
    ../../modules/bundles/gaming.nix

    # System modules
    ../../modules/system/hardware/nvidia.nix
  ];

  # Enable full desktop environment
  # This automatically enables: browsers, communication, productivity, media bundles
  # along with shared desktop modules (base, fonts, xdg, theming, printing)
  modules = {
    desktop.full.enable = true;

    # Enable gaming bundle
    bundles.gaming.enable = true;

    # Hardening baseline (pilot host) — workstation profile keeps userns on
    # for Steam/Chromium sandboxing and skips the linux-hardened kernel so
    # NVIDIA DKMS keeps working.
    system.hardening = {
      enable = true;
      profile = "workstation";
    };

    # Enable NVIDIA drivers (beta)
    system.hardware.nvidia = {
      enable = true;
      useBeta = true;
    };
  };
}
