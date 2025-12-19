# Graphics testing and debugging utilities
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    mesa-demos # glxgears, glxinfo, eglinfo
    vulkan-tools # vkcube, vulkaninfo
    glmark2 # OpenGL benchmark
    clinfo # OpenCL info
    wayland-utils # Wayland debugging tools
  ];
}
