{ inputs, lib, pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    # Theming
    libsForQt5.qt5ct
    qt6ct
    qt5.qtwayland
    qt6.qtwayland
    qt5.qtbase
    qt6.qtbase
    qt5Full
    kdePackages.full
    candy-icons
    papirus-icon-theme
    libsForQt5.qtstyleplugin-kvantum
    libsForQt5.plasma-framework
    kdePackages.qtstyleplugin-kvantum
    inputs.rose-pine-hyprcursor.packages.${pkgs.system}.default
    rose-pine-cursor
    gnome-themes-extra
    sweet
    sweet-folders
    nwg-look
  ];

  environment.pathsToLink = [ "/share/Kvantum" "/share/icons" "/share/pixmaps" ];

  xdg.icons.enable = true;
  xdg.menus.enable = true;
}
