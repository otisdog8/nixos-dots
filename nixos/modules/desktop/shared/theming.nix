# Theming configuration - Qt, GTK, icons, cursors
{
  config,
  lib,
  pkgs,
  username,
  inputs,
  ...
}:
let
  cfg = config.modules.desktop.shared.theming;
in
{
  options.modules.desktop.shared.theming = {
    enable = lib.mkEnableOption "theming configuration";
  };

  config = lib.mkIf cfg.enable {
    environment = {
      # Theme packages
      systemPackages = with pkgs; [
        # Qt theming
        qt6Packages.qt6ct
        qt6.qtwayland
        qt6.qtbase
        qt6.qtdeclarative
        qt6.qtsvg
        qt6.qtimageformats
        qt6.qt5compat
        kdePackages.qtstyleplugin-kvantum
        sweet-nova

        # Icons and cursors
        candy-icons
        papirus-icon-theme
        inputs.rose-pine-hyprcursor.packages.${pkgs.stdenv.hostPlatform.system}.default
        rose-pine-cursor

        # GTK themes
        gnome-themes-extra
        sweet

        # Theme configuration tool
        nwg-look
      ];

      # Theme DATA (share/themes/Sweet/…, share/Kvantum, share/icons) must be in the
      # system profile so it resolves both on the host and when gui.nix binds
      # /run/current-system/sw/<path> into sandboxes. Without this the theme NAME is
      # set but the files aren't found → silent Adwaita fallback. These entries are
      # the SAME list gui.nix binds (lib/sandbox-theme-paths.nix), imported here so
      # the two can't drift apart. /share/pixmaps is theming-local (gui.nix doesn't
      # bind it), so it stays inline.
      pathsToLink = [
        "/share/pixmaps"
      ]
      ++ import ../../../../lib/sandbox-theme-paths.nix;

      # Persistence for theming
      persistence."/persist" = {
        users.${username} = {
          files = [
            ".face.icon"
            ".face"
          ];
        };
      };
    };

    # Home-manager theming config for default user
    home-manager.users.${username} = {
      gtk = {
        enable = true;
        cursorTheme = {
          package = pkgs.rose-pine-cursor;
          name = "BreezeX-RosePine-Linux";
        };
        iconTheme = {
          name = "candy-icons";
        };
        # The "Sweet" theme lives in pkgs.sweet — NOT gnome-themes-extra (which
        # only ships Adwaita/Adwaita-dark/HighContrast), so the old package
        # reference meant GTK found no "Sweet" dir and silently fell back to
        # Adwaita. gnome-themes-extra stays installed (systemPackages) for the
        # Adwaita fallback + libadwaita bits.
        theme = {
          package = pkgs.sweet;
          name = "Sweet";
        };
        gtk4.theme = {
          package = pkgs.sweet;
          name = "Sweet";
        };
      };

      qt = {
        enable = true;
        platformTheme.name = "qt6ct";
        # qt6ct and the Kvantum plugin must be in the per-user profile:
        # home-manager points QT_PLUGIN_PATH (incl. for systemd user services like
        # the portal share picker) only at /etc/profiles/per-user, never
        # /run/current-system/sw, and installs nothing itself for the name "qt6ct"
        # (its package map only knows "qtct"). qt6ct with an unloadable
        # style=kvantum recurses in QProxyStyle and segfaults. style.name stays
        # unset so qt6ct.conf keeps picking the style.
        platformTheme.package = pkgs.qt6Packages.qt6ct;
        style.package = pkgs.kdePackages.qtstyleplugin-kvantum;
        qt6ctSettings = {
          Appearance = {
            # Resolved from the installed qt6ct, not a hardcoded store path that
            # goes stale on update and gets garbage-collected.
            color_scheme_path = "${pkgs.qt6Packages.qt6ct}/share/qt6ct/colors/airy.conf";
            custom_palette = false;
            icon_theme = "candy-icons";
            standard_dialogs = "default";
            style = "kvantum";
          };
          Fonts = {
            fixed = ''"DejaVu Sans,12,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"'';
            general = ''"DejaVu Sans,12,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"'';
          };
          Interface = {
            activate_item_on_single_click = 1;
            buttonbox_layout = 0;
            cursor_flash_time = 1000;
            dialog_buttons_have_icons = 1;
            double_click_interval = 400;
            gui_effects = "@Invalid()";
            keyboard_scheme = 2;
            menus_have_icons = true;
            show_shortcuts_in_context_menus = true;
            stylesheets = "@Invalid()";
            toolbutton_style = 4;
            underline_shortcut = 1;
            wheel_scroll_lines = 3;
          };
          Troubleshooting = {
            force_raster_widgets = 1;
            ignored_applications = "@Invalid()";
          };
        };
      };

      home.file = {
        ".config/Kvantum/kvantum.kvconfig" = {
          text = builtins.readFile (inputs.self + "/config/kvantum");
        };
        ".config/rofi/config.rasi" = {
          text = builtins.readFile (inputs.self + "/config/rofi");
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
    };
  };
}
