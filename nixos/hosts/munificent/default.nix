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
  networking.hostName = "munificent";
  time.timeZone = "America/Los_Angeles";

  boot = {
    supportedFilesystems = [ "btrfs" ];
    initrd = {
      supportedFilesystems = [ "nfs" ];
      kernelModules = [ "nfs" ];
    };
  };

  imports = [
    ./disks.nix

    # Hardware
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    inputs.nixos-hardware.nixosModules.common-gpu-amd
    inputs.nixos-hardware.nixosModules.common-pc
    inputs.nixos-hardware.nixosModules.common-pc-ssd

    # Desktop environment
    ../../modules/desktop/full

    # System modules
    ../../modules/system/hardware/amd.nix
    ../../modules/system/k3s
  ];

  # Enable full desktop environment, AMD GPU, and K3s
  modules = {
    desktop.full.enable = true;

    # Enable AMD GPU
    system.hardware.amd.enable = true;

    # K3s cluster node
    system.k3s = {
      enable = true;
      serverAddr = "https://100.126.30.73:6443";
      extraFlags = [
        "--bind-address=100.65.16.13"
        "--node-ip=100.65.16.13"
        "--advertise-address=100.65.16.13"
      ];
    };

    # System hardening baseline (k3s-node profile leaves /tmp on disk for kubelet).
    system.hardening = {
      enable = true;
      profile = "k3s-node";
      blacklistAfAlg = true;
    };

    # Post-unlock PCR 15 verification for TPM2 LUKS unlock.
    # Bootstrap pass: measurement only, no enforcement. After a known-good boot,
    # capture with `sudo systemd-analyze pcrs 15 --json=short`, paste the sha256
    # into expectedPcr15, rebuild, and reboot.
    system.pcr-verification = {
      enable = true;
      expectedPcr15 = "8f2d8bcfd3e57f0ab4691dd53a339e2c365e4b475307a534485ddbde7d8c88e9";
    };
  };

  # Firewall deferred — see DNS.md (rollout) for the per-host flip recipe.
  networking.firewall.enable = lib.mkForce false;
}
