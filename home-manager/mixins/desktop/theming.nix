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
  gtk = {
    enable = true;
    cursorTheme = {
      package = pkgs.rose-pine-cursor;
      name = "BreezeX-RosePine-Linux";
    };
    iconTheme = {
      name = "candy-icons";
    };
    theme = {
      package = pkgs.gnome-themes-extra;
      name = "Sweet";
    };
  };
  qt = {
    enable = true;
    platformTheme.name = "qt5ct";
  };
  home.file = {
    ".config/Kvantum/kvantum.kvconfig" = {
      text = builtins.readFile ../../../config/kvantum;
    };
    ".config/qt6ct/qt6ct.conf" = {
      text = builtins.readFile ../../../config/qt6ct;
    };
    ".config/rofi/config.rasi" = {
      text = builtins.readFile ../../../config/rofi;
    };
  };
  programs.fuzzel = {
    enable = true;
    settings.main = {
      font = "monospace:size=6";
      icon-theme = "candy-icons";
      lines = 25;
      width = 90;
      horizontal-pad = 20;
      vertical-pad = 0;
    };
  };
  services.mako = {
    enable = true;
    borderColor = "#282a36";
    extraConfig = builtins.readFile ../../../config/mako;
  };
  programs.wezterm = {
    enable = true;
    package = inputs.wezterm-flake.packages.${pkgs.system}.default;
    extraConfig = builtins.readFile ../../../config/wezterm;
  };
}
