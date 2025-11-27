{
  inputs,
  lib,
  pkgs,
  ...
}:
{
  environment.systemPackages = with pkgs; [
    # Theming
    qt6Packages.qt6ct
    qt6.qtwayland
    qt6.qtbase
    qt6.qtdeclarative
    qt6.qtsvg
    qt6.qtimageformats
    qt6.qt5compat
    candy-icons
    papirus-icon-theme
    kdePackages.qtstyleplugin-kvantum
    inputs.rose-pine-hyprcursor.packages.${pkgs.stdenv.hostPlatform.system}.default
    rose-pine-cursor
    gnome-themes-extra
    sweet
    nwg-look
  ];

  environment.pathsToLink = [
    "/share/Kvantum"
    "/share/icons"
    "/share/pixmaps"
  ];

  xdg.icons.enable = true;
  xdg.menus.enable = true;
}
