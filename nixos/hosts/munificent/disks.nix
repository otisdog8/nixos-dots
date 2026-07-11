# Disko layout for munificent — INTERIM (pre-SATA) form, mirroring arquitens/carrack.
#
# Ceph rides a raw LVM LV on the NVMe for now; when the enterprise SATA PLP SSD
# arrives, migrate the OSD and reclaim with `lvremove /dev/vg/ceph` +
# `lvextend -l +100%FREE /dev/vg/data && xfs_growfs /data` (no repartition).
#
#   GPT: ESP (1G) + LUKS (rest)
#        LUKS -> LVM VG "vg" -> { btrfs "pool", xfs "data", raw "ceph", swap }
#
# SIZES BELOW ASSUME A 2TB DRIVE (~1863 GiB). If munificent keeps a 1TB drive,
# change pool/data/ceph to something like 200G / 200G / 400G (and note that a
# smaller Ceph OSD here caps per-host usable capacity for a host-failure-domain
# size=3 pool).
{ ... }:
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
  disko.devices = {
    disk.main = {
      type = "disk";
      # munificent's 9100 Pro 2TB via the USB->NVMe bridge (real serial ...L311834A).
      # Becomes nvme-...L311834A once internal in munificent; runtime uses partlabels.
      device = "/dev/disk/by-id/ata-Samsung_SSD_9100_PRO_2TB_S7YCNJ0L311834A";
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

          luks = {
            priority = 2;
            name = "luks";
            size = "100%";
            content = {
              type = "luks";
              # Unique mapper name (NOT "luks") so `cryptsetup open` doesn't
              # collide with the minting workstation's own /dev/mapper/luks.
              name = "cryptmunificent"; # -> /dev/mapper/cryptmunificent
              settings = {
                allowDiscards = true;
                bypassWorkqueues = true;
              };
              content = {
                type = "lvm_pv";
                vg = "vg";
              };
            };
          };
        };
      };
    };

    lvm_vg.vg = {
      type = "lvm_vg";
      lvs = {
        pool = {
          size = "400G";
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
            };
          };
        };

        data = {
          size = "400G";
          content = {
            type = "filesystem";
            format = "xfs";
            mountpoint = "/data";
            mountOptions = [ "noatime" ];
          };
        };

        # Raw interim Ceph OSD — no content (rook claims /dev/vg/ceph directly).
        ceph = {
          size = "768G";
        };

        # zswap backing device — already encrypted (inside cryptmunificent), no
        # hibernation, TRIM freed slots. See modules/system/zswap.nix.
        swap = {
          size = "16G";
          content = {
            type = "swap";
            resumeDevice = false;
            discardPolicy = "both";
          };
        };
      };
    };
  };

  # btrfs pool lives on the LV, so point the rollback service at it.
  modules.system.impermanence.rollbackDevice = "/dev/vg/pool";

  fileSystems = {
    "/mnt/btrfs_root".neededForBoot = true;
    "/nix".neededForBoot = true;
    "/persist".neededForBoot = true;
    "/large".neededForBoot = true;
    "/cache".neededForBoot = true;
    "/dots".neededForBoot = true;
    "/data".neededForBoot = true;

    "/mnt/net-k8s" = {
      device = "recusant:/export/k8s";
      fsType = "nfs";
    };
  };

  boot.initrd.supportedFilesystems = [ "xfs" ];

  services.fstrim.enable = true;
}
