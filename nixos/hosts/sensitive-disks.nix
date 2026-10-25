# A sensitive guest's disks (hosts/sensitive-common.nix), each found by the
# serial the machine gives it (hosts/<machine>-hv):
#
#   virtio-sensitive-root  vg/sensitive: btrfs, the impermanence subvolumes
#                          (root, rolled back every boot, persist, large,
#                          cache, dots)
#   virtio-sensitive-swap  vg/sensitive-swap: zswap's backing swap
#   virtio-sensitive-data  vg/sensitive-data: XFS /data, k3s's (etcd,
#                          containerd, local PVs) and LINSTOR's storage pool
#
# No LUKS of their own: they're inside the machine's.
{ ... }:
let
  root = "/dev/disk/by-id/virtio-sensitive-root";
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

    "/data" = {
      device = "/dev/disk/by-id/virtio-sensitive-data";
      fsType = "xfs";
      options = [ "noatime" ];
      neededForBoot = true;
    };
  };

  swapDevices = [
    {
      device = "/dev/disk/by-id/virtio-sensitive-swap";
      discardPolicy = "both";
    }
  ];

  boot.initrd.supportedFilesystems = [
    "btrfs"
    "xfs"
  ];

  services.fstrim.enable = true;
}
