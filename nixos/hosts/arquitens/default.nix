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
  networking.hostName = "arquitens";
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

    # K3s cluster init node (primary)
    system.k3s = {
      enable = true;
      clusterInit = true;
      extraFlags = [
        "--bind-address=100.126.30.73"
        "--node-ip=100.126.30.73"
        "--advertise-address=100.126.30.73"
      ];
    };

    # System hardening baseline (k3s-node profile leaves /tmp on disk, which
    # matters here because arquitens NFS-exports /tmp to the tailnet).
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
      expectedPcr15 = "6ba225e9fc4ae2686ca24282c82ad1c9c1a07a82b3d8b73e527a6b116cdfc3ea";
    };
  };

  # NFS server
  services.nfs.server.enable = true;
  services.nfs.server.exports = ''
    /tmp 100.0.0.0/8(rw,nohide,insecure,no_subtree_check,all_squash)
  '';

  # Firewall deferred — see DNS.md (rollout) for the per-host flip recipe.
  networking.firewall.enable = lib.mkForce false;
}
