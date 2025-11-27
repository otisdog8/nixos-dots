# Screen recording and screenshot capabilities
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    ({ lib, ... }: {
      dbus.policies = lib.mkMerge [
        (lib.mkIf config.dbus.enable {
          "org.freedesktop.portal.ScreenCast" = "talk";
          "org.freedesktop.portal.Screenshot" = "talk";
        })
      ];
    })
  ];
}
