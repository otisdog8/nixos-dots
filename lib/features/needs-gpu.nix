# GPU acceleration feature (for gaming, 3D, video editing)
{ config, lib, ... }:

{
  imports = [ ../app-spec.nix ];

  config.app = {
    sandbox = {
      binds = lib.mkDefault [
        "/dev/dri"
        "/dev/nvidia0"
        "/dev/nvidiactl"
        "/dev/nvidia-modeset"
        "/dev/nvidia-uvm"
        "/dev/nvidia-uvm-tools"
      ];

      bind-rw = lib.mkDefault [
        "/sys/dev/char"
        "/sys/devices"
      ];

      bind-ro = lib.mkDefault [
        "/sys/class/drm"
        "/run/opengl-driver"
        "/run/opengl-driver-32"
        "/etc/egl"
        "/etc/vulkan"
        "/etc/OpenCL"
        "/run/current-system/sw/share/glvnd"
        "/run/current-system/sw/share/vulkan"
      ];
    };
  };
}
