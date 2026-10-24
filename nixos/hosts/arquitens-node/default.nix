# The k3s node "arquitens", as a VM on the machine arquitens-hv
# (modules/system/node-vm.nix). Same node as hosts/arquitens, the bare-metal
# config it replaces: the same etcd member, Rook OSD and mon, local PVs
# (its disks, disks.nix), and the same identity, which the conversion moved
# into its /persist: ssh host keys, Tailscale state (100.126.30.73, so k3s's
# addresses and every peer's serverAddr stay valid), machine-id, hostd's
# pairing and TOTP secrets, the Ceph disk's LUKS key. docs/node-vms.md.
#
# What the hardware gave and a VM doesn't: Secure Boot and the TPM (the
# machine's LUKS is what encrypts this one's disks at rest), and the iGPU
# (immich's machine-learning pod: docs/node-vms.md). Its system is built and
# booted by the machine, from the machine's store: deploy it by rebuilding
# arquitens-hv, then `sudo node-vm restart node` there.
{
  inputs,
  lib,
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

    inputs.nixos-hardware.nixosModules.common-pc-ssd

    ../../modules/desktop/full
    ../../modules/system/k3s
  ];

  modules = {
    desktop.full.enable = false;
    # Booted by the machine, its store over virtio-fs (node-vm.nix).
    system.nodeVmGuest.enable = true;
    system.secureboot.enable = false;
    system.virt.enable = false;

    # As on bare metal (hosts/arquitens).
    system.k3s = {
      enable = true;
      serverAddr = "https://100.103.225.29:6443"; # carrack
      persistDir = "/data";
      liveMigration = true;
      cephLoopback = false;
      podCIDR = "10.42.0.0/24"; # Cilium cluster-pool allocation (cilium-dbg node list)
      extraFlags = [
        "--bind-address=100.126.30.73"
        "--node-ip=100.126.30.73"
        "--advertise-address=100.126.30.73"
      ];
    };

    # The same disk, same LUKS, same keyfile (/persist/ceph-luks.key, moved
    # here), so the same /dev/vgceph/ceph Rook names for this node.
    system.cephOsdDisk = {
      enable = true;
      device = "/dev/disk/by-id/virtio-node-ceph";
    };

    # Root in this VM is the main cluster, not the machine: the tiers stay
    # what they were on bare metal.
    agentAuth.hostCommands = {
      user.enable = true;
      user.shells = true;
      root.enable = true;
      root.shells = true;
    };

    system.zswap.enable = true;

    system.hardening = {
      enable = true;
      profile = "k3s-node";
      blacklistAfAlg = true;
    };
  };

  # The VM's NIC carries the dongle's MAC, so netconsole's "arquitens" entry
  # (10.0.0.10, enx00242788a9c4) is this VM's as it was the machine's. Its
  # collector stays carrack's.
  modules.system.netconsole = {
    collectorIp = "10.0.0.11"; # carrack
    collectorMac = "00:24:27:88:a9:bc";
  };

}
