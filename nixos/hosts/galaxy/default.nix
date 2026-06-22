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
      blacklistAfAlg = true;
    };

    # Bootstrap pass: measurement only, no enforcement. Capture
    # PCR 15 on a known-good boot with
    # `systemd-analyze pcrs 15 --json=short`, then set expectedPcr15.
    system.pcr-verification = {
      enable = true;
      expectedPcr15 = "440e25ba3289b1461cdd57ea062e4e43f714c5725863f1498b5b96256781647b";
    };

    # Enable NVIDIA drivers (beta)
    system.hardware.nvidia = {
      enable = true;
      useBeta = false;
      # Single-GPU host: keep videoDrivers exactly ["nvidia"] (the module now
      # merges by default to support multi-GPU/roaming hosts).
      forceVideoDrivers = true;
    };
  };
}
