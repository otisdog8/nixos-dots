# XDG portals for file chooser and URI opening
#
# Portals all live on ONE bus name (org.freedesktop.portal.Desktop); FileChooser,
# OpenURI, ScreenCast, … are INTERFACES on it, not bus names. So a policy like
# `"org.freedesktop.portal.FileChooser" = "talk"` matches nothing, and
# `"org.freedesktop.portal.Desktop" = "talk"` hands the app EVERY portal —
# ScreenCast, Screenshot, RemoteDesktop, Camera, Location, GlobalShortcuts.
# Instead the name is only visible ("see") and calls are allowed per interface
# (xdg-dbus-proxy --call=NAME=INTERFACE.METHOD@PATH). Features that need a
# sensitive portal add their interface via `portalInterfaces` below (see
# screen-capture.nix, camera.nix).
{ config, lib, ... }:
let
  desktop = "org.freedesktop.portal.Desktop";
  portalPath = "/org/freedesktop/portal/desktop";
in
{
  imports = [ ../app-spec.nix ];

  options.app.portalInterfaces = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = ''
      Portal interfaces (short names, e.g. "ScreenCast") this app may call on
      org.freedesktop.portal.Desktop, in addition to xdg.nix's benign baseline.
    '';
  };

  config.app = {
    # Baseline: portals that are either user-mediated (a dialog the user drives)
    # or read-only/harmless. Deliberately NOT here: ScreenCast, Screenshot,
    # RemoteDesktop, InputCapture, Camera, Location, GlobalShortcuts, Background,
    # Wallpaper, Account, Clipboard, DynamicLauncher.
    portalInterfaces = [
      "FileChooser"
      "OpenURI"
      "Email"
      "Print"
      "Trash"
      "Notification"
      "Inhibit"
      "Settings"
      "NetworkMonitor"
      "ProxyResolver"
      "MemoryMonitor"
      "PowerProfileMonitor"
      "Realtime"
      "GameMode"
      "Secret"
    ];

    nixpakModules = [
      (
        { lib, ... }:
        {
          dbus = {
            enable = true;
            mountDocumentPortal = true;
            policies = {
              "org.freedesktop.DBus" = "talk";
              ${desktop} = "see";
            };
            rules.call.${desktop} =
              map (i: "org.freedesktop.portal.${i}.*@${portalPath}") (lib.unique config.app.portalInterfaces)
              ++ [
                # Version/property reads and introspection of the portal object.
                "org.freedesktop.DBus.Properties.Get@${portalPath}"
                "org.freedesktop.DBus.Properties.GetAll@${portalPath}"
                "org.freedesktop.DBus.Introspectable.Introspect@${portalPath}"
                # Handles returned by the calls above (cancel a dialog, end a session).
                "org.freedesktop.portal.Request.Close@${portalPath}/request/*"
                "org.freedesktop.portal.Session.Close@${portalPath}/session/*"
              ];
            rules.broadcast.${desktop} = [
              "org.freedesktop.portal.Request.Response@${portalPath}/request/*"
              "org.freedesktop.portal.Session.Closed@${portalPath}/session/*"
              # Theme / color-scheme changes (GTK, Qt, Electron follow these).
              "org.freedesktop.portal.Settings.SettingChanged@${portalPath}"
              "org.freedesktop.portal.NetworkMonitor.changed@${portalPath}"
              # Clicks on notification actions (GNotification/KNotifications use
              # the portal once they see /.flatpak-info).
              "org.freedesktop.portal.Notification.ActionInvoked@${portalPath}"
              "org.freedesktop.portal.Inhibit.StateChanged@${portalPath}/session/*"
              "org.freedesktop.portal.MemoryMonitor.LowMemoryWarning@${portalPath}"
              # PowerProfileMonitor/NetworkMonitor state is exposed as properties.
              "org.freedesktop.DBus.Properties.PropertiesChanged@${portalPath}"
            ];
          };

          # Bind system binaries so apps can call xdg-open and other tools
          bubblewrap.bind.ro = [
            "/run/current-system/sw/bin"
          ];
        }
      )
    ];
  };
}
