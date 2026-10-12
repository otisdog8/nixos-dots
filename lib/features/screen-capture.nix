# Screen recording and screenshot capabilities (xdg-desktop-portal).
# The host shows its own picker for every request; this only lets the app ASK.
{ config, lib, ... }:
{
  imports = [ ./xdg.nix ];

  config.app.portalInterfaces = [
    "ScreenCast"
    "Screenshot"
  ];
}
