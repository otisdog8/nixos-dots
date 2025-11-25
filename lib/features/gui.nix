# GUI application feature
{ config, lib, ... }:

{
  imports = [ ../app-spec.nix ];

  config.app = {
    # GUI apps typically have config and cache in standard locations
    persistence.user.persist = [
      ".config/${config.app.name}"
    ];

    persistence.user.volatileCache = [
      ".cache/${config.app.name}"
    ];

    # Nixpak configuration for GUI apps
    nixpakModules = [
      ({ config, lib, pkgs, sloth, ... }: {
        # Enable GPU access
        gpu.enable = lib.mkDefault true;

        # System integration
        fonts.enable = lib.mkDefault true;
        locale.enable = lib.mkDefault true;
        etc.sslCertificates.enable = lib.mkDefault true;

        # DBus for desktop integration
        dbus = {
          enable = lib.mkDefault true;
          policies = lib.mkDefault {
            "org.freedesktop.DBus" = "talk";
            "ca.desrt.dconf" = "talk";
            "org.freedesktop.portal.*" = "talk";
            "org.freedesktop.Notifications" = "talk";
          };
        };

        # Bubblewrap sandbox configuration
        bubblewrap = {
          # API VFS for device/process access
          apivfs = {
            dev = lib.mkDefault true;
            proc = lib.mkDefault true;
          };

          # Sockets for Wayland, audio
          sockets = {
            wayland = lib.mkDefault true;
            pulse = lib.mkDefault true;
            pipewire = lib.mkDefault true;
          };

          # Device access
          bind.dev = [
            "/dev/dri"  # GPU for rendering
          ];

          # Read-write bind mounts
          bind.rw = [
            "/tmp"  # Temp directory
            (sloth.concat' sloth.runtimeDir "/at-spi/bus")
            (sloth.concat' sloth.runtimeDir "/gvfsd")
            (sloth.concat' sloth.runtimeDir "/dconf")
            (sloth.concat' sloth.runtimeDir "/doc")
          ];

          # Read-only bind mounts
          bind.ro = [
            "/tmp/.X11-unix"
            "/run/current-system/sw/share/icons"
            "/run/current-system/sw/share/fonts"
            (sloth.concat' sloth.xdgConfigHome "/gtk-2.0")
            (sloth.concat' sloth.xdgConfigHome "/gtk-3.0")
            (sloth.concat' sloth.xdgConfigHome "/gtk-4.0")
            (sloth.concat' sloth.xdgConfigHome "/fontconfig")
            (sloth.concat' sloth.xdgConfigHome "/dconf")
          ];

          # Environment variables
          env = lib.mkDefault {
            DISPLAY = sloth.env "DISPLAY";
            WAYLAND_DISPLAY = sloth.env "WAYLAND_DISPLAY";
            QT_QPA_PLATFORMTHEME = sloth.env "QT_QPA_PLATFORMTHEME";
            LANG = sloth.env "LANG";
            XDG_DATA_DIRS = lib.makeSearchPath "share" [
              pkgs.adwaita-icon-theme
              pkgs.shared-mime-info
            ];
            XCURSOR_PATH = lib.concatStringsSep ":" [
              "${pkgs.adwaita-icon-theme}/share/icons"
              "${pkgs.adwaita-icon-theme}/share/pixmaps"
            ];
          };
        };
      })
    ];
  };
}
