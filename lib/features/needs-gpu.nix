# GPU acceleration feature (for gaming, 3D, video editing)
{ config, lib, ... }:

{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    ({ config, lib, ... }: {
      # Enable full GPU acceleration
      gpu = {
        enable = lib.mkDefault true;
        provider = lib.mkDefault "bundle";  # Bundle GPU drivers
      };

      # Device binds for NVIDIA and other GPUs
      bubblewrap.bind.dev = [
        "/dev/dri"
        "/dev/nvidia0"
        "/dev/nvidiactl"
        "/dev/nvidia-modeset"
        "/dev/nvidia-uvm"
        "/dev/nvidia-uvm-tools"
      ];

      # Read-write sys access for GPU
      bubblewrap.bind.rw = [
        "/sys/dev/char"
        "/sys/devices"
      ];

      # Read-only GPU-related paths
      bubblewrap.bind.ro = [
        "/sys/class/drm"
        "/run/opengl-driver"
        "/run/opengl-driver-32"
        "/etc/egl"
        "/etc/vulkan"
        "/etc/OpenCL"
        "/run/current-system/sw/share/glvnd"
        "/run/current-system/sw/share/vulkan"
      ];
    })
  ];
}
