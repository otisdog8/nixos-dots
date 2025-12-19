# XDG configuration - portals, MIME types, icons
{
  config,
  lib,
  pkgs,
  username,
  inputs,
  ...
}:
let
  cfg = config.modules.desktop.shared.xdg;
in
{
  options.modules.desktop.shared.xdg = {
    enable = lib.mkEnableOption "XDG configuration";
  };

  config = lib.mkIf cfg.enable {
    # XDG icons and menus
    xdg.icons.enable = true;
    xdg.menus.enable = true;

    # XDG portal configuration (system-level)
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

    # XDG desktop portal packages
    environment.systemPackages = with pkgs; [
      xdg-desktop-portal
      xdg-desktop-portal-gtk
    ];

    # Home-manager XDG config for default user
    home-manager.users.${username} = {
      xdg.portal = {
        enable = true;
        xdgOpenUsePortal = true;
        config.common = {
          default = [
            "hyprland"
            "gtk"
          ];
          "org.freedesktop.impl.portal.Secret" = [ "kwallet" ];
        };
        config.hyprland = {
          default = [
            "hyprland"
            "gtk"
          ];
          "org.freedesktop.impl.portal.Secret" = [ "kwallet" ];
        };
        extraPortals = [
          pkgs.kdePackages.xdg-desktop-portal-kde
          pkgs.xdg-desktop-portal-gtk
        ];
      };

      # Browser default applications are now configured via modules.apps.*.isDefaultBrowser
      xdg.mimeApps = {
        enable = true;
        defaultApplications = {
          "inode/directory" = [ "pcmanfm-qt.desktop" ];
        };
        associations.added = {
          "inode/directory" = [ "pcmanfm-qt.desktop" ];
        };
      };
    };
  };
}
