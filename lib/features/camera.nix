# Webcam/camera access via the Camera portal and direct V4L2 device nodes.
#
# Device nodes are bound individually (bind-try: absent ones are skipped): the
# first two cameras (each exposes a capture + a metadata node). Kept small so
# IR cameras, capture cards and v4l2loopback devices aren't exposed wholesale.
# Only cameras present at app start are visible.
{ config, lib, ... }:
{
  imports = [ ./xdg.nix ];

  config.app = {
    portalInterfaces = [ "Camera" ];

    nixpakModules = [
      (_: {
        bubblewrap.bind.dev = map (n: "/dev/video${toString n}") (lib.range 0 3);
      })
    ];
  };
}
