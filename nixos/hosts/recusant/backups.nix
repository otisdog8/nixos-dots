# Recusant snapshot configuration
{ lib, pkgs, ... }:
{
  imports = [
    ../../modules/system/snapshots.nix
  ];

  # Enable BTRFS snapshots. `persist` holds all impermanence-backed service state
  # (garage, attic, agent-auth, hindsight, host keys, secret.jwe, …), so hourly
  # snapshots give point-in-time recovery for the whole host; `mc` covers the
  # minecraft world. Both are top-level subvolumes (see disks.nix). Snapshots land
  # in /mnt/btrfs_root/btrbk_snapshots per the module default.
  modules.system.snapshots = {
    enable = true;
    subvolumes = [
      "persist"
      "mc"
    ];
  };
}
