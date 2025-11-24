# GUI application feature
{ config, lib, ... }:

{
  imports = [ ../app-spec.nix ];

  config.app = {
    # GUI apps typically have config and cache in standard locations
    persistence.user.persist = lib.mkDefault [
      ".config/${config.app.name}"
    ];

    persistence.user.volatileCache = lib.mkDefault [
      ".cache/${config.app.name}"
    ];

    # Sandbox configuration for GUI apps
    sandbox = {
      gui = lib.mkDefault true;

      apivfs = {
        dev = lib.mkDefault true;
        proc = lib.mkDefault true;
      };

      dbus = {
        enable = lib.mkDefault true;
        policies = lib.mkDefault {
          "org.freedesktop.DBus" = "talk";
          "ca.desrt.dconf" = "talk";
          "org.freedesktop.portal.*" = "talk";
          "org.freedesktop.Notifications" = "talk";
        };
      };

      binds = lib.mkDefault [
        "/dev/dri"  # Basic GPU for rendering
      ];

      sockets = lib.mkDefault [
        "wayland"
        "pulse"
        "pipewire"
      ];

      bind-rw = lib.mkDefault [
        "/tmp"  # Temp directory
      ];

      bind-ro = lib.mkDefault [
        "/tmp/.X11-unix"
        "/run/current-system/sw/share/icons"
        "/run/current-system/sw/share/fonts"
      ];

      env = lib.mkDefault [
        "DISPLAY"
        "WAYLAND_DISPLAY"
        "QT_QPA_PLATFORMTHEME"
        "LANG"
      ];
    };
  };
}
