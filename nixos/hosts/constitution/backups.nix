# Constitution snapshot configuration
{ lib, pkgs, ... }:
{
  imports = [
    ../../modules/system/snapshots.nix
  ];

  # Enable BTRFS snapshots with btrbk
  modules.system.snapshots = {
    enable = true;
    subvolumes = [ "persist" "large" "dots" ];
  };
}
