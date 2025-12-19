_: {

  boot.initrd.luks.devices."luks".device = "/dev/disk/by-uuid/d6e818fc-2128-479c-9feb-9c56f6489218";

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
      device = "/dev/disk/by-uuid/CEA4-5E32";
      fsType = "vfat";
      options = [
        "fmask=0022"
        "dmask=0022"
      ];
    };
  };

  swapDevices = [
    {
      device = "/dev/nvme0n1p3";
      randomEncryption.enable = true;
    }
  ];

}
