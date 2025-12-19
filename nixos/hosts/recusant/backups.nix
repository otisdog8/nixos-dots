# Recusant snapshot configuration
{ lib, pkgs, ... }:
{
  imports = [
    ../../modules/system/snapshots.nix
  ];

  # Enable BTRFS snapshots for minecraft server data
  modules.system.snapshots = {
    enable = true;
    subvolumes = [ "mc" ];
  };
}
