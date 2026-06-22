# Disko layout for the portable "liveusb" stick.
#
# GPT: ESP (1G) + encrypted random-key swap (32G) + LUKS (rest) -> btrfs subvols.
# disko auto-generates fileSystems.*, boot.initrd.luks.devices.luks and
# swapDevices from this, so the host imports inputs.disko.nixosModules.disko +
# this file INSTEAD of a hand-written disks.nix.
#
# Mint with:  disko-install --flake .#liveusb --disk main /dev/sdX
# `size = "100%"` on the LUKS partition fills any 128G-512G stick.
{ ... }:
let
  # Same btrfs options every other host uses.
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
  disko.devices.disk.main = {
    type = "disk";
    # Overridden at mint time by `disko-install --disk main /dev/sdX`.
    device = "/dev/disk/by-id/PLACEHOLDER";
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

        # Encrypted swap with a fresh random key every boot. Referenced by
        # partlabel (the random key erases any UUID/label on each boot).
        # Sized to match the live-mode tmpfs cap (32G) so a full tmpfs always
        # fits in RAM + swap on any machine (no OOM-deadlock — see default.nix).
        swap = {
          priority = 2;
          name = "swap";
          size = "32G";
          content = {
            type = "swap";
            randomEncryption = true;
          };
        };

        # Everything else: LUKS -> btrfs, fills the stick.
        luks = {
          priority = 3;
          name = "luks";
          size = "100%";
          content = {
            type = "luks";
            name = "luks"; # -> /dev/mapper/luks (matches every other host)
            settings.allowDiscards = true;
            # No passwordFile/keyFile -> disko prompts for the passphrase at mint.
            content = {
              type = "btrfs";
              extraArgs = [ "-f" ];
              # The bare btrfs top-level (subvolid 5), mirroring other hosts.
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
        };
      };
    };
  };
}
