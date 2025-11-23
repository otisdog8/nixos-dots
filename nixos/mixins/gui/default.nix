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
    ./desktop.nix
    ./fonts.nix
    ./plymouth.nix
    ./printing.nix
    ./sddm.nix
    ./theming.nix
  ];
  environment.systemPackages = with pkgs; [
    # Apps
    lxqt.pcmanfm-qt
    protonvpn-gui
    code-cursor
    chromium
    vesktop
    kitty
    inputs.zen-browser.packages."${system}".default
    _1password-cli
    _1password-gui
    steam
    kdePackages.ark
    prismlauncher-sandboxed
    zoom-us
    brave
    otisdog8.amazing-marvin
    tetrio-desktop
    quartus-prime-lite
    discord
    lunar-client
    slipstream
    obsidian
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
  services.udisks2.enable = true;

  nixpkgs = {
    overlays = [
      outputs.overlays.otisdog8-packages
      outputs.overlays.sandboxed-packages
      outputs.overlays.custom-packages
    ];
  };
}
