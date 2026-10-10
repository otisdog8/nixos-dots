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

          "org.freedesktop.StatusNotifierWatcher" = "talk";
        };
        # The item's own bus name, which the app registers with the watcher:
        # <prefix>-<pid>-<id> (org.freedesktop: Chromium/Electron; org.kde: Qt,
        # libappindicator). A "<prefix>.*" policy doesn't cover these (it
        # matches <prefix>.x only), so our proxy build has --own-numbered
        # (overlays/xdg-dbus-proxy-own-numbered.patch): the app may own
        # <prefix>-<digits>[-<digits>...] and nothing else, and gets no access
        # to another app's item by it. Apps that register under their
        # connection's unique name (1Password) need neither.
        dbus.args = [
          "--own-numbered=org.kde.StatusNotifierItem"
          "--own-numbered=org.freedesktop.StatusNotifierItem"
        ];
      }
    )
  ];
}
