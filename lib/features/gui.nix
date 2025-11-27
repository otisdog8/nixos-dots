# GUI application feature
{ config, lib, ... }:

{
  imports = [ ../app-spec.nix ];

  config.app = {
    # GUI apps should specify their own persistence paths
    # (removed automatic .config/${name} and .cache/${name} defaults)

    # Nixpak configuration for GUI apps
    nixpakModules = [
      ({ config, lib, pkgs, sloth, ... }: {
        # System integration
        fonts.enable = true;
        locale.enable = true;
        etc.sslCertificates.enable = true;

        # Bubblewrap sandbox configuration
        bubblewrap = {
          # API VFS for device/process access
          apivfs = {
            dev = true;
            proc = true;
          };

          # Sockets for Wayland, audio
          sockets = {
            wayland = true;
            pulse = true;
            pipewire = true;
          };

          # Device access
          bind.dev = [
            "/dev/dri"  # GPU for rendering
          ];

          # Read-write bind mounts
          bind.rw = [
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
          env = {
            DISPLAY = sloth.env "DISPLAY";
            WAYLAND_DISPLAY = sloth.env "WAYLAND_DISPLAY";
            QT_QPA_PLATFORMTHEME = sloth.env "QT_QPA_PLATFORMTHEME";
            LANG = sloth.env "LANG";
          };
        };
      })
    ];
  };
}
