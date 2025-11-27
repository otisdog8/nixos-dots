# Convenience feature combining XDG portals + notifications
{ config, lib, ... }:
{
  imports = [
    ./xdg.nix
    ./notifications.nix
  ];
}
