# The k3s node "munificent", as a VM on the machine munificent-hv
# (modules/system/node-vm.nix). Same node as hosts/munificent, the bare-metal
# config it replaces: the same etcd member, Rook OSD and mon, local PVs
# (its disks, disks.nix), and the same identity, which the conversion moved
# into its /persist: ssh host keys, Tailscale state (100.65.16.13, so k3s's
# addresses and every peer's serverAddr stay valid), machine-id, hostd's
# pairing and TOTP secrets, the Ceph disk's LUKS key. docs/node-vms.md.
#
# What the hardware gave and a VM doesn't: Secure Boot and the TPM (the
# machine's LUKS is what encrypts this one's disks at rest), and the iGPU
# (immich's machine-learning pod: docs/node-vms.md). Its system is built and
# booted by the machine, from the machine's store: deploy it by rebuilding
# munificent-hv, then `sudo node-vm restart node` there.
{
  inputs,
  lib,
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

    # As on bare metal (hosts/munificent).
    system.k3s = {
      enable = true;
      serverAddr = "https://100.126.30.73:6443"; # arquitens
      persistDir = "/data";
      liveMigration = true;
      cephLoopback = false;
      cephLanPeers = [ "10.0.0.10/32" "10.0.0.11/32" "10.0.0.12/32" ]; # Ceph on the LAN (docs: lcm docs/ceph-lan.md)
      podCIDR = "10.42.2.0/24"; # Cilium cluster-pool allocation (cilium-dbg node list)
      extraFlags = [
        "--bind-address=100.65.16.13"
        "--node-ip=100.65.16.13"
        "--advertise-address=100.65.16.13"
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

  # The VM's NIC carries the dongle's MAC, so netconsole's "munificent" entry
  # (enx00242788a9cd) is this VM's as it was the machine's. It sends to
  # the default collector, arquitens (the node VM, at the same address).

}
