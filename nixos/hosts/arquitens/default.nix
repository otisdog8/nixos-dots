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

  # Enable full desktop environment, AMD GPU, and K3s
  modules = {
    desktop.full.enable = true;

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
      # disko names this host's LUKS "cryptarquitens" (mint-collision avoidance).
      deviceName = "cryptarquitens";
      expectedPcr15 = "ea66c8b7ae01bb530fb964abebd4ec43441229e3beeb1941f5a7a157743ddc19";
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
