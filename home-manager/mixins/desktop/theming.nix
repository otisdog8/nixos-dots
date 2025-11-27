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
    platformTheme.name = "qt6ct";
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
    settings = {
      border-color = "#282a36";
      "urgency=low" = {
        "border-color" = "#282a36";
      };
      "urgency=normal" = {
        "border-color" = "#f1fa8c";
      };
      "urgency=high" = {
        "border-color" = "#ff5555";
      };
    };
  };
  programs.kitty = lib.mkForce {
  enable = true;
  
  # Font configuration
  font = {
    name = "JetBrainsMono Nerd Font Mono style=ExtraLight";
    size = 10.0;
  };
  
  settings = {
    font_family = "family='JetBrainsMono Nerd Font' style=ExtraLight";
    font_size = "10";
    # Scrollback
    scrollback_lines = 65536;
    
    # Tab bar configuration
    tab_bar_edge = "bottom";
    tab_bar_min_tabs = 2;
    tab_bar_style = "powerline";
    tab_powerline_style = "slanted";

    # Sweet Eliverlara color scheme
    foreground = "#C3C7D1";
    background = "#282C34";
    
    # Cursor colors
    cursor = "#C3C7D1";
    cursor_text_color = "#282C34";
    
    # Black
    color0 = "#282C34";
    color8 = "#282C34";
    
    # Red
    color1 = "#ED254E";
    color9 = "#ED254E";
    
    # Green
    color2 = "#71F79F";
    color10 = "#71F79F";
    
    # Yellow
    color3 = "#F9DC5C";
    color11 = "#F9DC5C";
    
    # Blue
    color4 = "#7CB7FF";
    color12 = "#7CB7FF";
    
    # Magenta
    color5 = "#C74DED";
    color13 = "#C74DED";
    
    # Cyan
    color6 = "#00C1E4";
    color14 = "#00C1E4";
    
    # White
    color7 = "#DCDFE4";
    color15 = "#DCDFE4"; 
  };
    shellIntegration.enableZshIntegration = true;
};
}
