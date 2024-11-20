{ inputs, lib, pkgs, username, ... }:
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
    libsForQt5.qtstyleplugin-kvantum
    libsForQt5.plasma-framework
    kdePackages.qtstyleplugin-kvantum
    inputs.rose-pine-hyprcursor.packages.${pkgs.system}.default
    rose-pine-cursor
    sweet
(
  symlinkJoin {
    name = "sweet-wrapped";
    paths = [ pkgs.sweet-nova ];
    nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
    postBuild = ''
     rm $out/share/sddm/themes/Sweet/assets/bg.jpg
     ln -s ${inputs.self}/images/wallpaper.jpg $out/share/sddm/themes/Sweet/assets/bg.jpg
    '';
  }
)
  ];

  system.activationScripts.copyIcon = ''
    mkdir -p /var/lib/AccountsService/icons
    cp ${inputs.self}/images/face.png /var/lib/AccountsService/icons/${username}
    chmod 755 /var/lib/AccountsService
    chmod 755 /var/lib/AccountsService/icons
    chmod 644 /var/lib/AccountsService/icons/${username}
  '';
  services.displayManager.sddm.package = pkgs.libsForQt5.sddm;
  services.displayManager.sddm.wayland.enable = true;
  services.displayManager.sddm.enable = true;
  services.displayManager.sddm.theme = "Sweet";
  services.displayManager.defaultSession = "hyprland";
}
