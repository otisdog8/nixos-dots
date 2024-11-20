{ inputs, lib, pkgs, ... }:
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
    polkit-kde-agent
    kwallet-pam
    mako
    kwalletmanager
    hypridle
    hyprpaper
    xdg-desktop-portal-hyprland
    xdg-desktop-portal
    xdg-desktop-portal-kde
    xdg-desktop-portal-gtk
    blueman
    networkmanager-openvpn
    networkmanagerapplet
    kdePackages.networkmanager-qt
    udisks
    udiskie
  ];

  services.libinput.enable = true;
  programs.hyprland.enable = true; # enable Hyprland
  programs.hyprland.package = inputs.hyprland.packages."${pkgs.system}".hyprland;

  programs.obs-studio = {
    enable = true;
    enableVirtualCamera = true;
  };
  programs.ydotool = {
    enable = true;
  };
  services.logind = {
    powerKey = "ignore";
    lidSwitch = "ignore";
  };
  services.pipewire = {
     enable = true;
     pulse.enable = true;
     jack.enable = true;
     alsa.enable = true;
     alsa.support32Bit = true;
wireplumber.extraConfig.bluetoothEnhancements = {
  "monitor.bluez.properties" = {
      "bluez5.enable-sbc-xq" = true;
      "bluez5.enable-msbc" = true;
      "bluez5.enable-hw-volume" = true;
      "bluez5.roles" = [ "hsp_hs" "hsp_ag" "hfp_hf" "hfp_ag" ];
  };
};

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
    extraPortals = [
      pkgs.xdg-desktop-portal-kde
      pkgs.xdg-desktop-portal-gtk
    ];
  };

  services.udisks2.enable = true;
services.blueman.enable = true;
hardware.bluetooth.enable = true;
}
