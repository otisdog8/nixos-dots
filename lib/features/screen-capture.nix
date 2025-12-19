# Screen recording and screenshot capabilities
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    (
      { lib, ... }:
      {
        dbus.enable = true;
        dbus.policies = {
          "org.freedesktop.portal.ScreenCast" = "talk";
          "org.freedesktop.portal.Screenshot" = "talk";
        };
      }
    )
  ];
}
