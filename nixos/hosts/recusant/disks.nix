{
  ...
}:
let
  btrfsOpts = [
    "compress=zstd"
    "noatime"
  ];
  subvol = mountpoint: {
    inherit mountpoint;
    mountOptions = btrfsOpts;
  };
in
{
  # Single-drive disko layout for the Samsung 990 Pro 4TB.
  #
  # NO LVM (unlike arquitens/carrack): recusant needs only one btrfs pool + swap
  # on this disk — the bulk media/k8s data lives on the separate bcachefs HDD —
  # and btrfs subvolumes already share the pool's free space dynamically, so
  # there's nothing to pre-size or resize. The siblings use LVM only because they
  # slice one disk into btrfs + XFS(etcd) + raw-Ceph + swap; recusant has none of
  # those, so LVM would be a pure-overhead device-mapper layer.
  #
  #   GPT: ESP(1G) + swap(16G, randomEncryption) + LUKS(rest) -> btrfs subvols
  #
  # LUKS mapper is "cryptrecusant" (NOT "luks") so `disko` can format this drive
  # LIVE from the running old SSD without colliding with its already-open
  # /dev/mapper/luks. deviceName + rollbackDevice below are threaded to match.
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_4TB_S7KGNU0XB08984L";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          priority = 1;
          name = "ESP";
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [
              "fmask=0022"
              "dmask=0022"
            ];
          };
        };

        # Backing swap for zswap. Per-boot randomEncryption (recusant has
        # nohibernate, so an ephemeral key is fine) — same as the old layout, just
        # declarative now. zswap keeps most cold pages compressed in RAM; this is
        # only the overflow tier, so 16G is ample. See modules/system/zswap.nix.
        swap = {
          priority = 2;
          name = "swap";
          size = "16G";
          content = {
            type = "swap";
            randomEncryption = true;
            discardPolicy = "both";
            resumeDevice = false;
          };
        };

        luks = {
          priority = 3;
          name = "luks";
          size = "100%";
          content = {
            type = "luks";
            name = "cryptrecusant"; # -> /dev/mapper/cryptrecusant
            settings = {
              # TRIM passthrough so the weekly fstrim reaches the SSD (dm-crypt
              # drops discards otherwise). Reveals which ciphertext blocks are
              # unused, not their contents — the standard SSD-vs-LUKS compromise.
              allowDiscards = true;
              bypassWorkqueues = true;
            };
            content = {
              type = "btrfs";
              extraArgs = [ "-f" ];
              mountpoint = "/mnt/btrfs_root";
              mountOptions = btrfsOpts;
              subvolumes = {
                "/root" = subvol "/";
                "/nix" = subvol "/nix";
                "/persist" = subvol "/persist";
                "/large" = subvol "/large";
                "/cache" = subvol "/cache";
                "/dots" = subvol "/dots";
                "/mc" = subvol "/mc";
              };
            };
          };
        };
      };
    };
  };

  # btrfs pool now lives on /dev/mapper/cryptrecusant (was the default
  # /dev/mapper/luks); point the initrd impermanence rollback service at it.
  modules.system.impermanence.rollbackDevice = "/dev/mapper/cryptrecusant";

  fileSystems = {
    # neededForBoot parity: impermanence binds these out of /persist in early
    # boot, so they must be mounted in initrd. disko emits the fileSystems
    # entries from the subvolumes above; these just add the flag (they merge).
    "/mnt/btrfs_root".neededForBoot = true;
    "/nix".neededForBoot = true;
    "/persist".neededForBoot = true;
    "/large".neededForBoot = true;
    "/cache".neededForBoot = true;
    "/dots".neededForBoot = true;
    "/mc".neededForBoot = true;

    # Separate physical devices — NOT disko-managed, preserved from the old
    # layout. The bcachefs HDD auto-unlocks via clevis (secret.jwe in /persist);
    # see default.nix.
    "/mnt/largedev_root" = {
      device = "/dev/disk/by-uuid/0bddf9fb-bbbe-4046-b77f-00c5f4d3094e";
      fsType = "btrfs";
    };

    "/mnt/bcachefs" = {
      device = "/dev/disk/by-id/ata-HUH721212ALE601_2AG2SR1Y";
      fsType = "bcachefs";
      options = [
        "nofail"
      ];
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
  };
}
