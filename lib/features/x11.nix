# X11 socket for apps that need X11 compatibility — capability-based.
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];
  config.app.capabilities.x11 = true;
}
