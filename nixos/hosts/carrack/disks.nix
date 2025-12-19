_: {

  boot.initrd.luks.devices."luks".device = "/dev/nvme0n1p2";

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
      device = "/dev/nvme0n1p1";
      fsType = "vfat";
      options = [
        "fmask=0022"
        "dmask=0022"
      ];
    };

    "/mnt/net-k8s" = {
      device = "recusant:/export/k8s";
      fsType = "nfs";
    };
  };

  swapDevices = [
    {
      device = "/dev/nvme0n1p3";
      randomEncryption.enable = true;
    }
  ];

}
