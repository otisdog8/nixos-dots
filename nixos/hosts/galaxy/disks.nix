_: {

  boot.initrd.luks.devices."luks".device = "/dev/disk/by-uuid/e2a1e108-9026-40fe-a294-a2f849b5ad77";

  fileSystems = {
    "/" = {
      device = "/dev/mapper/luks";
      fsType = "btrfs";
      options = [
        "subvol=root"
        "compress=zstd"
        "noatime"
      ];
    };

    "/mnt/btrfs_root" = {
      device = "/dev/mapper/luks";
      fsType = "btrfs";
      neededForBoot = true;
    };

    "/large" = {
      device = "/dev/mapper/luks";
      fsType = "btrfs";
      options = [
        "subvol=large"
        "compress=zstd"
        "noatime"
      ];
      neededForBoot = true;
    };

    "/cache" = {
      device = "/dev/mapper/luks";
      fsType = "btrfs";
      options = [
        "subvol=cache"
        "compress=zstd"
        "noatime"
      ];
      neededForBoot = true;
    };

    "/baked" = {
      device = "/dev/mapper/luks";
      fsType = "btrfs";
      options = [
        "subvol=baked"
        "compress=zstd"
        "noatime"
        "ro" # Read-only mount
      ];
      neededForBoot = true;
    };

    "/dots" = {
      device = "/dev/mapper/luks";
      fsType = "btrfs";
      options = [
        "subvol=dots"
        "compress=zstd"
        "noatime"
      ];
      neededForBoot = true;
    };

    "/persist" = {
      device = "/dev/mapper/luks";
      fsType = "btrfs";
      options = [
        "subvol=persist"
        "compress=zstd"
        "noatime"
      ];
      neededForBoot = true;
    };

    "/nix" = {
      device = "/dev/mapper/luks";
      fsType = "btrfs";
      options = [
        "subvol=nix"
        "compress=zstd"
        "noatime"
      ];
      neededForBoot = true;
    };

    "/boot" = {
      device = "/dev/disk/by-uuid/79C1-26A9";
      fsType = "vfat";
      options = [
        "fmask=0022"
        "dmask=0022"
      ];
    };
  };

}
