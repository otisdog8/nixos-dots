# munificent as a hypervisor: the same disk as hosts/munificent/disks.nix, read
# differently. The machine boots from it (ESP, LUKS, the btrfs pool, swap) and
# hands the rest to its VM whole, never mounting it:
#
#   LUKS -> LVM VG "vg" -> { btrfs "pool" (this machine), swap (this machine),
#                            xfs "data" (the node VM's /data: etcd, local PVs),
#                            "node", "node-swap" (the node VM's state, swap) }
#
# "data" keeps its filesystem: the VM mounts the very XFS the bare-metal node
# did, so etcd, Rook's mon state and the local PVs move without a copy.
# "node" and "node-swap" are new (docs/node-vms.md): small, as the VM's
# system and store are this machine's (node-vm.nix). The interim
# "ceph" LV of hosts/munificent/disks.nix isn't here: the OSD is on the SATA SSD,
# which goes to the VM whole too (hosts/munificent-hv). If `lvs` still lists it,
# nothing uses it.
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
              name = "cryptmunificent";
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

        # The node VM's: no content here, so nothing on this machine mounts or
        # formats them.
        data = {
          size = "400G";
        };
        node = {
          size = "32G";
        };
        node-swap = {
          size = "16G";
        };

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

  modules.system.impermanence.rollbackDevice = "/dev/vg/pool";

  fileSystems = {
    "/mnt/btrfs_root".neededForBoot = true;
    "/nix".neededForBoot = true;
    "/persist".neededForBoot = true;
    "/large".neededForBoot = true;
    "/cache".neededForBoot = true;
    "/dots".neededForBoot = true;
  };

  services.fstrim.enable = true;
}
