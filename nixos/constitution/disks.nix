# /dev/disk/by-id/nvme-SAMSUNG_MZVL2512HCJQ-00B00_S675NL0W253602 -> ../../nvme0n1
_: {

  boot.initrd.luks.devices."luks".device = "/dev/disk/by-uuid/1a259459-627b-4112-88b4-569c4fb24660";

  fileSystems."/" =
    { device = "/dev/disk/by-uuid/fa3ce55b-21ee-4fb3-bbb0-c4208e203223";
      fsType = "btrfs";
      options = [ "subvol=root" "compress=zstd" "noatime" ];
    };

  fileSystems."/mnt/btrfs_root" =
    { device = "/dev/disk/by-uuid/fa3ce55b-21ee-4fb3-bbb0-c4208e203223";
      fsType = "btrfs";
      neededForBoot = true;
    };


  fileSystems."/large" =
    { device = "/dev/disk/by-uuid/fa3ce55b-21ee-4fb3-bbb0-c4208e203223";
      fsType = "btrfs";
      options = [ "subvol=large" "compress=zstd" "noatime" ];
      neededForBoot = true;
    };


  fileSystems."/cache" =
    { device = "/dev/disk/by-uuid/fa3ce55b-21ee-4fb3-bbb0-c4208e203223";
      fsType = "btrfs";
      options = [ "subvol=cache" "compress=zstd" "noatime" ];
      neededForBoot = true;
    };


  fileSystems."/persist" =
    { device = "/dev/disk/by-uuid/fa3ce55b-21ee-4fb3-bbb0-c4208e203223";
      fsType = "btrfs";
      options = [ "subvol=persist" "compress=zstd" "noatime" ];
      neededForBoot = true;
    };

  fileSystems."/nix" =
    { device = "/dev/disk/by-uuid/fa3ce55b-21ee-4fb3-bbb0-c4208e203223";
      fsType = "btrfs";
      options = [ "subvol=nix" "compress=zstd" "noatime" ];
      neededForBoot = true;
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/7A63-677D";
      fsType = "vfat";
      options = [ "fmask=0022" "dmask=0022" ];
    };

  swapDevices = [ {
    device = "/dev/nvme0n1p3";
    randomEncryption.enable = true;
  } ];

}
