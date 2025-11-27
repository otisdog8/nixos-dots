{
  hostname,
  inputs,
  lib,
  pkgs,
  username,
  config,
  ...
}:
{
  networking.hostName = "galaxy";
  time.timeZone = "America/Los_Angeles";

  boot.supportedFilesystems = [ "btrfs" ];
  boot.blacklistedKernelModules = [ "amdgpu" ];

  imports = [
    ./disks.nix
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    inputs.nixos-hardware.nixosModules.common-pc
    inputs.nixos-hardware.nixosModules.common-pc-ssd
    ../modules/apps/obsidian.nix
    ../modules/apps/vesktop.nix
    ../modules/apps/zen-browser.nix
    ../modules/apps/firefox.nix
    ../modules/apps/brave.nix
    ../modules/apps/chromium.nix
    ../modules/apps/zoom.nix
    ../modules/apps/tetrio-desktop.nix
    ../modules/apps/lunar-client.nix
    ../modules/apps/steam.nix
    ../modules/apps/amazing-marvin.nix
    ../modules/apps/obs-studio.nix
    ../modules/apps/prismlauncher.nix
    ../modules/apps/slipstream.nix
    ../modules/apps/protonvpn-gui.nix
  ];

  # Enable apps via modular system
  modules.apps.obsidian = {
    enable = true;
    sandbox.enable = true;
    vaultPath = "Documents/obsidian";
  };

  modules.apps.vesktop = {
    enable = true;
    sandbox.enable = true;
  };

  modules.apps.zen-browser = {
    enable = true;
    sandbox.enable = true;
  };

  modules.apps.firefox = {
    enable = true;
    sandbox.enable = true;
  };

  modules.apps.brave = {
    enable = true;
    sandbox.enable = true;
  };

  modules.apps.chromium = {
    enable = true;
    sandbox.enable = true;
  };

  modules.apps.zoom = {
    enable = true;
    sandbox.enable = true;
  };

  modules.apps.tetrio-desktop = {
    enable = true;
    sandbox.enable = true;
  };

  modules.apps.lunar-client = {
    enable = true;
    sandbox.enable = true;
  };

  modules.apps.steam = {
    enable = true;
    sandbox.enable = true;
  };

  modules.apps.amazing-marvin = {
    enable = true;
    sandbox.enable = true;
  };

  modules.apps.obs-studio = {
    enable = true;
    sandbox.enable = true;
  };

  modules.apps.prismlauncher = {
    enable = true;
    sandbox.enable = true;
  };

  modules.apps.slipstream = {
    enable = true;
    sandbox.enable = true;
  };

  modules.apps.protonvpn-gui = {
    enable = true;
    sandbox.enable = false;
  };

  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia.open = true;
  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.beta;
  hardware.nvidia.modesetting.enable = true;
}
