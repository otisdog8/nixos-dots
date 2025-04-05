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
  imports = [
    ./hypridle.nix
    ./hyprland.nix
    ./hyprlock.nix
    ./hyprpaper.nix
    ./theming.nix
    ./waybar.nix
    ./wlogout.nix
    ./xdg.nix
  ];
  dconf.settings = {
    "org/virt-manager/virt-manager/connections" = {
      autoconnect = [ "qemu:///system" ];
      uris = [ "qemu:///system" ];
    };
  };
  services.kdeconnect = {
    enable = true;
    indicator = true;
  };
  programs.foot.enable = true;
  services.udiskie.enable = true;
  services.trayscale.enable = true;
  programs.zathura.enable = true;
  programs.texlive.enable = true;
  programs.obs-studio = {
    enable = true;
    plugins = with pkgs.obs-studio-plugins; [
      wlrobs
      obs-backgroundremoval
      obs-pipewire-audio-capture
    ];
  };
  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "inode/directory" = [ "pcmanfm-qt.desktop" ];
    };
    associations.added = {
      "inode/directory" = [ "pcmanfm-qt.desktop" ];
    };
  };
}
