_: {

  boot.initrd.luks.devices."luks".device = "/dev/disk/by-uuid/f03de5de-c3b9-4300-8dc4-b49a826918d8";

  fileSystems."/" =
    { device = "/dev/mapper/luks";
      fsType = "btrfs";
      options = [ "subvol=root" "compress=zstd" "noatime" ];
    };

  fileSystems."/mnt/btrfs_root" =
    { device = "/dev/mapper/luks";
      fsType = "btrfs";
      neededForBoot = true;
    };


  fileSystems."/large" =
    { device = "/dev/mapper/luks";
      fsType = "btrfs";
      options = [ "subvol=large" "compress=zstd" "noatime" ];
      neededForBoot = true;
    };


  fileSystems."/cache" =
    { device = "/dev/mapper/luks";
      fsType = "btrfs";
      options = [ "subvol=cache" "compress=zstd" "noatime" ];
      neededForBoot = true;
    };


  fileSystems."/dots" =
    { device = "/dev/mapper/luks";
      fsType = "btrfs";
      options = [ "subvol=cache" "compress=zstd" "noatime" ];
      neededForBoot = true;
    };


  fileSystems."/persist" =
    { device = "/dev/mapper/luks";
      fsType = "btrfs";
      options = [ "subvol=persist" "compress=zstd" "noatime" ];
      neededForBoot = true;
    };

  fileSystems."/nix" =
    { device = "/dev/mapper/luks";
      fsType = "btrfs";
      options = [ "subvol=nix" "compress=zstd" "noatime" ];
      neededForBoot = true;
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/49C3-8293";
      fsType = "vfat";
      options = [ "fmask=0022" "dmask=0022" ];
    };

  swapDevices = [ {
    device = "/dev/sdb3";
    randomEncryption.enable = true;
  } ];

}
