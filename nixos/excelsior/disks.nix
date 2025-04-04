_: {

  boot.initrd.luks.devices."luks".device = "/dev/disk/by-uuid/b9c68457-7c6b-4e56-9142-93944047a4e4";

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
    device = "/dev/disk/by-uuid/CEA4-5E32";
    fsType = "vfat";
    options = [
      "fmask=0022"
      "dmask=0022"
    ];
  };

  swapDevices = [
    {
      device = "/dev/nvme0n1p3";
      randomEncryption.enable = true;
    }
  ];

}
