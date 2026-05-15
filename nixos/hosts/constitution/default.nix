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

  # Enable system hardening baseline (workstation profile)
  modules.system.hardening.enable = true;

  # Post-unlock PCR 15 verification for TPM2 LUKS auto-unlock.
  # See nixos/modules/system/PCR-VERIFICATION.md for the enrollment dance.
  modules.system.pcr-verification = {
    enable = true;
    # Boot 1: leave expectedPcr15 unset (measurement only).
    # Boot 2: capture via `sudo systemd-analyze pcrs 15 --json=short`,
    # paste the sha256 below, rebuild, reboot.
    expectedPcr15 = "177dbed8d982069ea26086d2679e2ba3387d8c175a91eab0a042ab0b0945ba74";
  };

  hardware.cpu.intel.updateMicrocode = true;
  boot.kernelModules = [ "kvm-intel" ];

  # Enable Intel iGPU (VA-API hardware video encode/decode)
  modules.system.hardware.intel = {
    enable = true;
    enableCompute = true;
  };

  programs.captive-browser.enable = true;
}
