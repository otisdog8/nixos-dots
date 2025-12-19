# Webcam/camera access via portal and direct device
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    (
      { lib, ... }:
      {
        dbus.enable = true;
        dbus.policies = {
          "org.freedesktop.portal.Camera" = "talk";
        };

        bubblewrap.bind.dev = [
          "/dev/video0"
          "/dev/video1"
        ];
      }
    )
  ];
}
