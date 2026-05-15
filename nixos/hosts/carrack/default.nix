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
  networking.hostName = "carrack";
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

  # Enable full desktop environment, AMD GPU, and K3s cluster node
  modules = {
    desktop.full.enable = true;
    system.hardware.amd.enable = true;
    system.k3s = {
      enable = true;
      serverAddr = "https://100.126.30.73:6443";
      extraFlags = [
        "--bind-address=100.103.225.29"
        "--node-ip=100.103.225.29"
        "--advertise-address=100.103.225.29"
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
      expectedPcr15 = "c64d3433ee08a9cca976ce57ed4e32a646f4dd22cb3005021dd23dbca8d7f019";
    };
  };

  # Firewall deferred — see DNS.md (rollout) for the per-host flip recipe.
  networking.firewall.enable = lib.mkForce false;
}
