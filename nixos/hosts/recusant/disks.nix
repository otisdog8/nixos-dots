{
  pkgs,
  ...
}:
{

  boot.initrd.luks.devices."luks" = {
    device = "/dev/disk/by-uuid/1d7cd1ea-6803-42bd-bbfd-659abfa846e2";
    # TRIM passthrough so the weekly fstrim (services.fstrim, on by default here)
    # and btrfs's own discards actually reach the SSD — dm-crypt drops them
    # otherwise. Trade-off: this reveals which ciphertext blocks are unused (not
    # their contents), the standard SSD-vs-LUKS compromise the other nodes accept.
    allowDiscards = true;
  };

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

    "/mnt/largedev_root" = {
      device = "/dev/disk/by-uuid/0bddf9fb-bbbe-4046-b77f-00c5f4d3094e";
      fsType = "btrfs";
    };

    "/export/k8s" = {
      device = "/mnt/bcachefs/k8s";
      fsType = "none";
      options = [
        "bind"
        "nofail"
      ];
    };

    "/media" = {
      device = "/mnt/bcachefs/k8s/media";
      fsType = "none";
      options = [
        "bind"
        "nofail"
      ];
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

    "/mc" = {
      device = "/dev/mapper/luks";
      fsType = "btrfs";
      options = [
        "subvol=mc"
        "compress=zstd"
        "noatime"
      ];
      neededForBoot = true;
    };

    "/boot" = {
      device = "/dev/disk/by-uuid/E7CD-C534";
      fsType = "vfat";
      options = [
        "fmask=0022"
        "dmask=0022"
      ];
    };

    "/mnt/bcachefs" = {
      device = "/dev/disk/by-id/ata-HUH721212ALE601_2AG2SR1Y";
      #device = "/dev/disk/by-uuid/bd79c925-1d8b-4e56-b91b-c1c4c5c303fc";
      fsType = "bcachefs";
      options = [
        "nofail"
      ];

    };
  };

  swapDevices = [
    {
      device = "/dev/disk/by-partuuid/db8f005c-41f6-4d38-8f6c-36985f60a6dd";
      randomEncryption = {
        enable = true;
        # TRIM freed swap slots (fstrim can't reach swap) so zswap's backing
        # device doesn't accumulate stale blocks on the SSD. On a randomEncryption
        # swap this reveals *which* blocks are unused (not their contents); an
        # acceptable trade for a scratch swap with no hibernation image.
        allowDiscards = true;
      };
      discardPolicy = "both";
    }
  ];

}
