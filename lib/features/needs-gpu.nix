# GPU acceleration feature (for gaming, 3D, video editing)
{ config, lib, ... }:

{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    (
      { lib, ... }:
      {
        # GPU binds
        bubblewrap.bind = {
          # Device binds for NVIDIA and other GPUs
          dev = [
            "/dev/dri"
            "/dev/nvidia0"
            "/dev/nvidiactl"
            "/dev/nvidia-modeset"
            "/dev/nvidia-uvm"
            "/dev/nvidia-uvm-tools"
          ];

          # Read-write sys access for GPU
          rw = [
            "/sys/dev/char"
            "/sys/devices"
          ];

          # Read-only GPU-related paths (matching prismlauncher-sandboxed)
          ro = [
            "/run/opengl-driver"
            "/run/opengl-driver-32"
            "/etc/static/egl"
            "/etc/egl"
            "/etc/vulkan"
            "/etc/OpenCL"
            "/run/current-system/sw/share/glvnd"
            "/run/current-system/sw/share/vulkan"
          ];
        };
      }
    )
  ];
}
