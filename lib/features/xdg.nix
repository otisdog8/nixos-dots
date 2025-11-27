# XDG portals for file chooser and URI opening
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    ({ lib, ... }: {
      dbus = {
        enable = true;
        mountDocumentPortal = true;
        policies = {
          "org.freedesktop.DBus" = "talk";
          "org.freedesktop.portal.Desktop" = "talk";
          "org.freedesktop.portal.FileChooser" = "talk";
          "org.freedesktop.portal.OpenURI" = "talk";
        };
      };
    })
  ];
}
