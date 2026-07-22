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
    ./backups.nix
    ./snapshots.nix
    inputs.sops-nix.nixosModules.sops

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

  # Host-wide sops-nix base config; per-secret declarations live next to their
  # consumers (e.g. ./backups.nix). Decryption uses the SSH host ed25519 key,
  # persisted under /persist by remote-access.nix (enabled by default).
  sops = {
    defaultSopsFile = ./secrets/constitution.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  };

  # Enable full desktop environment
  modules.desktop.full.enable = true;

  # Enable gaming bundle
  modules.bundles.gaming.enable = true;

  # Enable laptop power management
  modules.system.laptop.enable = true;

  # Enable system hardening baseline (workstation profile)
  modules.system.hardening = {
    enable = true;
    blacklistAfAlg = true;
  };

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
