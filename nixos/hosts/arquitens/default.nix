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

    # Enable AMD GPU
    system.hardware.amd.enable = true;

    # K3s server node. Post-disk-swap this REJOINS the existing cluster rather
    # than bootstrapping it: with a fresh (empty) etcd datadir, clusterInit=true
    # would spin up a brand-new single-member cluster with a new CA and split the
    # brain, so it joins via serverAddr instead. carrack + munificent hold quorum
    # (2/3) while arquitens is out; its tailscale IP (100.126.30.73) is preserved
    # via the restored /var/lib/tailscale, so their serverAddr/tls-san stay valid.
    # etcd + DB land on the XFS /data volume; Ceph uses the raw partition (no loop).
    system.k3s = {
      enable = true;
      serverAddr = "https://100.103.225.29:6443"; # carrack
      persistDir = "/data";
      cephLoopback = false;
      extraFlags = [
        "--bind-address=100.126.30.73"
        "--node-ip=100.126.30.73"
        "--advertise-address=100.126.30.73"
      ];
    };

    # Dedicated PLP SATA SSD for the Ceph OSD: LUKS2 (cryptceph, keyfile on
    # /persist) -> vgceph/ceph bare LV consumed by Rook. See the module for the
    # one-time imperative bootstrap (blkdiscard/luksFormat/lvcreate).
    system.cephOsdDisk = {
      enable = true;
      device = "/dev/disk/by-id/ata-MTFDDAK1T9TDS_221436ADEA78";
    };

    # Compressed swap (zswap). Backing LV lives in vg (see disks.nix), already
    # encrypted. writeback disabled on system.slice keeps the k3s/etcd cold pages
    # off the encrypted backing swap. Defaults: 20% pool, swappiness 30.
    system.zswap.enable = true;

    # System hardening baseline.
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
      # disko names this host's LUKS "cryptarquitens" (mint-collision avoidance).
      deviceName = "cryptarquitens";
      expectedPcr15 = "ea66c8b7ae01bb530fb964abebd4ec43441229e3beeb1941f5a7a157743ddc19";
    };
  };

  # NFS server removed: it exported /tmp rw to the whole 100.0.0.0/8 with
  # insecure + all_squash — a world-writable system dir served to the tailnet (and
  # then some, given the /8). Nothing mounts it. Re-add as a dedicated export dir
  # scoped to exact node IPs if arquitens ever needs to serve storage.

  # Firewall deferred — see DNS.md (rollout) for the per-host flip recipe.
  networking.firewall.enable = lib.mkForce false;
}
