{
  inputs,
  lib,
  pkgs,
  outputs,
  ...
}:
{
  imports = [
    ./auth.nix
    ./desktop.nix
    ./fonts.nix
    ./plymouth.nix
    ./sddm.nix
    ./theming.nix
  ];
  environment.systemPackages = with pkgs; [
    # Apps
    lxqt.pcmanfm-qt
    kitty
    _1password-cli
    _1password-gui
    kdePackages.ark
    quartus-prime-lite
    linux-firmware

    # Graphics test utilities
    mesa-demos  # Includes glxgears, glxinfo, eglinfo
    vulkan-tools  # Includes vkcube, vulkaninfo
    glmark2  # OpenGL benchmark
    clinfo  # OpenCL info
    wayland-utils  # Wayland debugging tools
  ];
  hardware.graphics = {
    enable = true;
  };
  hardware.graphics.enable32Bit = true;

  hardware.flipperzero.enable = true;

  # chaotic.mesa-git.enable = true;

  nixpkgs = {
    overlays = [
      outputs.overlays.otisdog8-packages
      outputs.overlays.sandboxed-packages
      outputs.overlays.custom-packages
    ];
  };
}
