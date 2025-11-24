_: {

  boot.initrd.luks.devices."luks".device = "/dev/disk/by-uuid/e2a1e108-9026-40fe-a294-a2f849b5ad77";

  fileSystems."/" = {
    device = "/dev/mapper/luks";
    fsType = "btrfs";
    options = [
      "subvol=root"
      "compress=zstd"
      "noatime"
    ];
  };

  fileSystems."/mnt/btrfs_root" = {
    device = "/dev/mapper/luks";
    fsType = "btrfs";
    neededForBoot = true;
  };

  fileSystems."/large" = {
    device = "/dev/mapper/luks";
    fsType = "btrfs";
    options = [
      "subvol=large"
      "compress=zstd"
      "noatime"
    ];
    neededForBoot = true;
  };

  fileSystems."/cache" = {
    device = "/dev/mapper/luks";
    fsType = "btrfs";
    options = [
      "subvol=cache"
      "compress=zstd"
      "noatime"
    ];
    neededForBoot = true;
  };

  fileSystems."/volatile-cache" = {
    device = "/dev/mapper/luks";
    fsType = "btrfs";
    options = [
      "subvol=volatile-cache"
      "compress=zstd"
      "noatime"
    ];
    neededForBoot = true;
  };

  fileSystems."/baked" = {
    device = "/dev/mapper/luks";
    fsType = "btrfs";
    options = [
      "subvol=baked"
      "compress=zstd"
      "noatime"
      "ro"  # Read-only mount
    ];
    neededForBoot = true;
  };

  fileSystems."/dots" = {
    device = "/dev/mapper/luks";
    fsType = "btrfs";
    options = [
      "subvol=dots"
      "compress=zstd"
      "noatime"
    ];
    neededForBoot = true;
  };

  fileSystems."/persist" = {
    device = "/dev/mapper/luks";
    fsType = "btrfs";
    options = [
      "subvol=persist"
      "compress=zstd"
      "noatime"
    ];
    neededForBoot = true;
  };

  fileSystems."/nix" = {
    device = "/dev/mapper/luks";
    fsType = "btrfs";
    options = [
      "subvol=nix"
      "compress=zstd"
      "noatime"
    ];
    neededForBoot = true;
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/79C1-26A9";
    fsType = "vfat";
    options = [
      "fmask=0022"
      "dmask=0022"
    ];
  };

}
