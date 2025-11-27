{
  inputs,
  lib,
  pkgs,
  ...
}:
{
  environment.systemPackages = with pkgs; [
    # Desktop
    grim
    slurp
    cliphist
    libnotify
    wlogout
    hyprlock
    hyprpaper
    grimblast
    wl-clipboard
    wofi
    tofi
    rofi
    fuzzel
    waybar
    brightnessctl
    kdePackages.kwallet
    hyprpolkitagent
    kdePackages.kwallet-pam
    mako
    kdePackages.kwalletmanager
    hypridle
    inputs.hyprland.packages."${pkgs.stdenv.hostPlatform.system}".hyprland
    xdg-desktop-portal-hyprland
    xdg-desktop-portal
    xdg-desktop-portal-gtk
    blueman
    networkmanager-openvpn
    networkmanagerapplet
    kdePackages.networkmanager-qt
    udisks
    udiskie
    pavucontrol
    gparted
  ];

  services.libinput.enable = true;
  programs.hyprland.enable = true; # enable Hyprland
  programs.hyprland.package = inputs.hyprland.packages."${pkgs.stdenv.hostPlatform.system}".hyprland;
  programs.hyprland.portalPackage = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;

  systemd.tmpfiles.rules = [
    "L+ /usr/share/xdg-desktop-portal/portals - - - - /run/current-system/sw/share/xdg-desktop-portal/portals "
    "L+ /usr/libexec/xdg-desktop-portal-gtk - - - - ${pkgs.xdg-desktop-portal-gtk}/libexec/xdg-desktop-portal-gtk "
    "L+ /usr/libexec/xdg-desktop-portal-hyprland - - - - ${pkgs.xdg-desktop-portal-hyprland}/libexec/xdg-desktop-portal-hyprland "
    "L+ /usr/libexec/xdg-desktop-portal - - - - ${pkgs.xdg-desktop-portal}/libexec/xdg-desktop-portal "
  ];

  programs.ydotool = {
    enable = true;
  };
  services.logind.settings.Login = {
    HandlePowerKey = "ignore";
    HandleLidSwitch = "ignore";
  };
  services.pipewire = {
    enable = true;
    pulse.enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    jack.enable = true;
  };

  services.playerctld.enable = true;

  xdg.portal = {
    enable = true;
    xdgOpenUsePortal = true;
    config.common = {
      default = [ "hyprland" ];
      "org.freedesktop.impl.portal.FileChooser" = [ "kde" ];
      "org.freedesktop.impl.portal.Secret" = [ "kwallet" ];
    };
    config.hyprland = {
      default = [ "hyprland" ];
      "org.freedesktop.impl.portal.FileChooser" = [ "kde" ];
      "org.freedesktop.impl.portal.Secret" = [ "kwallet" ];
    };
  };

  services.udisks2.enable = true;
  services.blueman.enable = true;
  hardware.bluetooth.enable = true;
}
