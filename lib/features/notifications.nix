# Desktop notifications
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    (
      { lib, ... }:
      {
        dbus = {
          enable = true;
          policies = {
            "org.freedesktop.DBus" = "talk";
            "org.freedesktop.Notifications" = "talk";
          };
        };
      }
    )
  ];
}
