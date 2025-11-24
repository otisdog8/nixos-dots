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
  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "default-web-browser" = [ "zen-beta.desktop" ];
      "text/html" = [ "zen-beta.desktop" ];
      "x-scheme-handler/http" = [ "zen-beta.desktop" ];
      "x-scheme-handler/https" = [ "zen-beta.desktop" ];
      "x-scheme-handler/about" = [ "zen-beta.desktop" ];
      "x-scheme-handler/unknown" = [ "zen-beta.desktop" ];
    };
  };
}
