{
  config,
  inputs,
  lib,
  outputs,
  pkgs,
  stateVersion,
  username,
  ...
}:
let
  inherit (pkgs.stdenv) isDarwin isLinux;
in
{
  xdg.portal = {
    enable = true;
    xdgOpenUsePortal = true;
    config.common = {
      default = [
        "hyprland"
        "gtk"
      ];
      #"org.freedesktop.impl.portal.FileChooser" = [ "kde" ];
      "org.freedesktop.impl.portal.Secret" = [ "kwallet" ];
    };
    config.hyprland = {
      default = [
        "hyprland"
        "gtk"
      ];
      #"org.freedesktop.impl.portal.FileChooser" = [ "kde" ];
      "org.freedesktop.impl.portal.Secret" = [ "kwallet" ];
    };
    extraPortals = [
      pkgs.kdePackages.xdg-desktop-portal-kde
      pkgs.xdg-desktop-portal-gtk
    ];
  };
  # Browser default applications are now configured via modules.apps.*.isDefaultBrowser
}
