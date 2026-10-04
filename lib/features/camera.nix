# Webcam/camera access via the Camera portal and V4L2 device nodes, on request.
#
# No camera at start. When the app starts (sandbox.vm.cameraOnLaunch) or asks
# (`sbx-request camera` inside), sbx-broker asks you, and on approval the host's
# UVC cameras are attached to the running sandbox: bound in as device nodes for
# a container (lib/broker/attach.py; a dedicated uid also gets an ACL on them
# until it stops), passed through over USB for a VM. Never IR cameras' other
# nodes, capture cards or v4l2loopback devices: UVC (uvcvideo) only.
{ config, lib, ... }:
{
  imports = [ ./xdg.nix ];

  config.app = {
    capabilities.camera = true;
    portalInterfaces = [ "Camera" ];
  };
}
