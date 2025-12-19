# System tray support feature
# Provides DBus access for StatusNotifierItem protocol (modern system tray)
{ config, lib, ... }:

{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    (
      { lib, ... }:
      {
        dbus.enable = true;
        dbus.policies = {
          # StatusNotifierWatcher - the system tray service
          "org.kde.StatusNotifierWatcher" = "talk";

          # StatusNotifierItem - apps own these to register with the tray
          # Apps dynamically create their own StatusNotifierItem service names
          "org.kde.StatusNotifierItem.*" = "own";

          # Alternative freedesktop tray protocol (legacy)
          "org.freedesktop.StatusNotifierItem" = "own";
          "org.freedesktop.StatusNotifierItem.*" = "own";
          "org.freedesktop.StatusNotifierWatcher" = "talk";
        };
      }
    )
  ];
}
