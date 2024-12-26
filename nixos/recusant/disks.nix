_: {

  boot.initrd.luks.devices."luks".device = "/dev/disk/by-uuid/1d7cd1ea-6803-42bd-bbfd-659abfa846e2";

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

  fileSystems."/mnt/largedev_root" =
    { device = "/dev/disk/by-uuid/0bddf9fb-bbbe-4046-b77f-00c5f4d3094e";
      fsType = "btrfs";
    };

  fileSystems."/export/k8s" = {
    device = "/mnt/largedev_root/k8s";
    options = [ "bind" ];
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
      options = [ "subvol=dots" "compress=zstd" "noatime" ];
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

  fileSystems."/mc" =
    { device = "/dev/mapper/luks";
      fsType = "btrfs";
      options = [ "subvol=mc" "compress=zstd" "noatime" ];
      neededForBoot = true;
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/E7CD-C534";
      fsType = "vfat";
      options = [ "fmask=0022" "dmask=0022" ];
    };

  swapDevices = [ {
    device = "/dev/nvme0n1p3";
    randomEncryption.enable = true;
  } ];

}
