# The arquitens node as a VM (hosts/arquitens-hv runs it). Its system and
# store are the machine's (node-vm.nix: /nix/store over virtio-fs, booted
# directly), so its disks hold only state, each found by the serial the
# machine gives it:
#
#   virtio-node-root  vg/node: btrfs, the impermanence subvolumes (root,
#                     rolled back every boot, persist, large, cache, dots),
#                     made by hand once (docs/node-vms.md)
#   virtio-node-swap  vg/node-swap: zswap's backing swap
#   virtio-node-data  the bare-metal node's XFS /data (vg/data), as it was:
#                     etcd, Rook's mon state, the local PVs
#   virtio-node-ceph  the Micron SATA SSD, whole: LUKS "cryptceph" -> vgceph/ceph,
#                     unlocked here (ceph-osd-disk.nix), where Rook expects it
#
# No LUKS of its own: everything but the Ceph disk is inside the machine's
# cryptarquitens.
{ ... }:
let
  root = "/dev/disk/by-id/virtio-node-root";
  subvol = name: {
    device = root;
    fsType = "btrfs";
    options = [
      "subvol=${name}"
      "compress=zstd"
      "noatime"
    ];
    neededForBoot = true;
  };
in
{
  modules.system.impermanence.rollbackDevice = root;

  fileSystems = {
    "/" = subvol "root";
    "/persist" = subvol "persist";
    "/large" = subvol "large";
    "/cache" = subvol "cache";
    "/dots" = subvol "dots";

    # k3s persists here (k3s module, persistDir), so it must be up in initrd.
    "/data" = {
      device = "/dev/disk/by-id/virtio-node-data";
      fsType = "xfs";
      options = [ "noatime" ];
      neededForBoot = true;
    };

    "/mnt/net-k8s" = {
      device = "recusant:/export/k8s";
      fsType = "nfs";
    };
  };

  swapDevices = [
    {
      device = "/dev/disk/by-id/virtio-node-swap";
      discardPolicy = "both";
    }
  ];

  boot.initrd.supportedFilesystems = [
    "btrfs"
    "xfs"
  ];

  services.fstrim.enable = true;
}
