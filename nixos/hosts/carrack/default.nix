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
    inputs.disko.nixosModules.disko
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

  # Headless K3s cluster node: no desktop (boots to multi-user.target; access via
  # SSH). AMD GPU driver kept for hardware/compute. Flip enable back to true to
  # use it as a workstation again.
  modules = {
    desktop.full.enable = false;
    system.hardware.amd.enable = true;
    # Rejoins via serverAddr (arquitens) with a fresh etcd datadir after the disk
    # swap — carrack was never clusterInit, so no split-brain risk. etcd + DB land
    # on the XFS /data volume; Ceph uses a raw LV (no loopback).
    system.k3s = {
      enable = true;
      serverAddr = "https://100.126.30.73:6443";
      persistDir = "/data";
      cephLoopback = false;
      extraFlags = [
        "--bind-address=100.103.225.29"
        "--node-ip=100.103.225.29"
        "--advertise-address=100.103.225.29"
      ];
    };

    # Dedicated PLP SATA SSD for the Ceph OSD: LUKS2 (cryptceph, keyfile on
    # /persist) -> vgceph/ceph bare LV consumed by Rook. See the module for the
    # one-time imperative bootstrap (blkdiscard/luksFormat/lvcreate).
    system.cephOsdDisk = {
      enable = true;
      device = "/dev/disk/by-id/ata-MTFDDAK1T9TDS_221436CB34AA";
    };

    # Compressed swap (zswap). Backing LV lives in vg (see disks.nix), already
    # encrypted. writeback disabled on system.slice keeps the k3s/etcd cold pages
    # off the encrypted backing swap. Defaults: 20% pool, swappiness 30.
    system.zswap.enable = true;

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
      # disko names this host's LUKS "cryptcarrack" (mint-collision avoidance).
      deviceName = "cryptcarrack";
      # null = bootstrap/measure-only. The fresh LUKS volume has a new master key,
      # so the OLD hash would drop you into the initrd emergency shell (as happened
      # on arquitens). Boot first, then capture the new value and set it.
      expectedPcr15 = "b353292a4797f1c859ea4bf77b0e327b0eb5045e9e6804d1fc1fc2fff39ef3a8";
    };
  };

  # Firewall deferred — see DNS.md (rollout) for the per-host flip recipe.
  networking.firewall.enable = lib.mkForce false;
}
