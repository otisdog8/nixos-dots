# Disko layout for carrack — INTERIM (pre-SATA) form, mirroring arquitens.
#
# Ceph rides a raw LVM LV on the NVMe for now; when the enterprise SATA PLP SSD
# arrives, migrate the OSD and reclaim with `lvremove /dev/vg/ceph` +
# `lvextend -l +100%FREE /dev/vg/data && xfs_growfs /data` (no repartition).
#
#   GPT: ESP (1G) + LUKS (rest)
#        LUKS -> LVM VG "vg" -> { btrfs "pool", xfs "data", raw "ceph" }
#
# SIZES BELOW ASSUME A 2TB DRIVE (~1863 GiB). If carrack keeps its 1TB S770,
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
      # carrack's 9100 Pro 2TB via the USB->NVMe bridge (real serial ...L311836Y).
      # Becomes nvme-...L311836Y once internal in carrack; runtime uses partlabels.
      device = "/dev/disk/by-id/ata-Samsung_SSD_9100_PRO_2TB_S7YCNJ0L311836Y";
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
              name = "cryptcarrack"; # -> /dev/mapper/cryptcarrack
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
