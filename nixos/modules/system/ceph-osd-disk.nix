# Dedicated Ceph OSD disk: LUKS2 (keyfile) -> LVM -> bare LV for Rook.
#
# Rook expects a raw block device at /dev/vgceph/ceph on each node and consumes
# it directly as a BlueStore OSD — the LV gets NO filesystem and is never
# mounted. Host-side LUKS instead of Ceph-managed dmcrypt because Ceph can't
# manage its own encryption keys right now (upstream bug), and the disk-level
# stack is simpler to reason about anyway.
#
# Stack (whole disk, no partition table):
#   LUKS2 "cryptceph" -> LVM PV -> VG "vgceph" -> LV "ceph" (100%FREE, bare)
#
# Unlock is a plain /etc/crypttab entry, NOT initrd/disko: this is a data disk,
# the node must boot without it (nofail), and systemd's crypttab generator
# already does exactly what's needed — it adds RequiresMountsFor= on the
# keyfile path, so the unlock orders after /persist (neededForBoot) where the
# keyfile lives. The OS disk's disko LUKS/LVM is untouched.
#
# Keyfile: /persist/ceph-luks.key — generated IMPERATIVELY per host (bootstrap
# below), root:root 0400. /persist is the impermanence-durable subvol inside
# the host's encrypted root LUKS, so the key survives reboots, is encrypted at
# rest, and never enters the nix store. Deliberately not sops-nix: sops
# materializes secrets at activation time, which races cryptsetup.target
# ordering, and the disk key has no reason to exist in the repo — the offline
# LUKS header backup is the recovery path.
#
# crypttab options:
#   discard             — pass TRIM through dm-crypt (BlueStore issues discards)
#   no-read-workqueue / — crypttab spelling of bypassWorkqueues=true (same as
#   no-write-workqueue    the root LUKS in each host's disks.nix): encrypt
#                         inline instead of bouncing through dm-crypt worker
#                         threads; lower, flatter latency on AES-NI CPUs.
#   nofail              — boot proceeds if the disk is missing/dead.
#
# LVM auto-activation needs nothing here: lvm2 udev event activation (already
# active for the root VG) picks up the PV when /dev/mapper/cryptceph appears
# and activates vgceph/ceph.
#
# The udev rule disables the drive's volatile write cache: the Micron 5300 PRO
# has power-loss protection, so "write through" is safe and (benchmarked)
# doubles sync-write IOPS on this model. Matches by model string, so it only
# ever touches these drives.
#
# ── One-time bootstrap (per node, IMPERATIVE — not run by nix) ──────────────
# Only after that node's old OSD is drained + purged and its deployment
# deleted (the disk is in use by Ceph until then). The disks contain remnants
# of a failed provisioning attempt; blkdiscard clears them.
#
#   DISK=/dev/disk/by-id/ata-MTFDDAK1T9TDS_<serial>
#   sudo blkdiscard -f $DISK
#   sudo install -m 0400 -o root -g root /dev/null /persist/ceph-luks.key
#   sudo dd if=/dev/urandom of=/persist/ceph-luks.key bs=512 count=1 conv=notrunc
#   sudo cryptsetup luksFormat --type luks2 --sector-size 4096 \
#        --key-file /persist/ceph-luks.key $DISK
#   sudo cryptsetup open --key-file /persist/ceph-luks.key --allow-discards \
#        $DISK cryptceph
#   sudo pvcreate /dev/mapper/cryptceph
#   sudo vgcreate vgceph /dev/mapper/cryptceph
#   sudo lvcreate -l 100%FREE -n ceph vgceph
#   sudo cryptsetup luksHeaderBackup $DISK \
#        --header-backup-file /root/cryptceph-$(hostname)-luks-header.img
#   # ...copy the header image somewhere offline, then delete it from /root.
#
# (--sector-size 4096: the 5300 PRO is 4K-native (512e); 4K dm-crypt sectors
# cut per-sector encryption overhead for BlueStore's 4K-aligned writes.)
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.system.cephOsdDisk;
in
{
  options.modules.system.cephOsdDisk = {
    enable = lib.mkEnableOption "dedicated LUKS-encrypted Ceph OSD disk";

    device = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/dev/disk/by-id/ata-MTFDDAK1T9TDS_221436ADEA78";
      description = ''
        Stable by-id path of the OSD disk. null = no disk yet: the write-cache
        udev rule still applies, but no crypttab entry is generated (munificent
        until its drive arrives).
      '';
    };

    keyFile = lib.mkOption {
      type = lib.types.str;
      default = "/persist/ceph-luks.key";
      description = ''
        LUKS keyfile path, root-readable only, on the (encrypted, persistent)
        root filesystem. Generated imperatively at bootstrap — never in the
        nix store.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        # The Micron 5300 PRO has power-loss protection, so the volatile write
        # cache buys nothing — every OSD sync write just pays for a cache flush.
        # "write through" lets the drive ack fsync from its capacitor-backed
        # buffer: measured 2x on arquitens (fio 4k randwrite fsync=1: 10.2k ->
        # 20.4k IOPS, avg sync latency 91us -> 43us). cache_type resets on power
        # cycle, hence udev. The glob stays specific to the 5300 PRO 1.92TB —
        # broader Micron globs (MTFDDAK*) would also catch non-PLP client drives,
        # where this would tank write performance. sysfs space-pads the model to
        # 16 chars, so the trailing * is load-bearing.
        # Verify after reboot: cat /sys/class/scsi_disk/*/cache_type
        services.udev.extraRules = ''
          ACTION=="add|change", SUBSYSTEM=="scsi_disk", ATTR{device/model}=="MTFDDAK1T9TDS*", ATTR{cache_type}="write through"
        '';

        # For the bootstrap commands (luksFormat/open/luksHeaderBackup).
        environment.systemPackages = [ pkgs.cryptsetup ];
      }

      (lib.mkIf (cfg.device != null) {
        environment.etc.crypttab.text = ''
          cryptceph ${cfg.device} ${cfg.keyFile} discard,no-read-workqueue,no-write-workqueue,nofail
        '';
      })
    ]
  );
}
