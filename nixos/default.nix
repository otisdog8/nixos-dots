# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).
{
  config,
  hostname,
  inputs,
  lib,
  modulesPath,
  outputs,
  pkgs,
  platform,
  stateVersion,
  username,
  ...
}:

{
  imports =
    [ # Include the results of the hardwae scan.
      inputs.hyprland.nixosModules.default
      inputs.impermanence.nixosModules.impermanence
      inputs.lanzaboote.nixosModules.lanzaboote
      inputs.chaotic.nixosModules.default # OUR DEFAULT MODULE
      inputs.home-manager.nixosModules.home-manager
      ./${hostname}
      {
        home-manager.extraSpecialArgs = { inherit inputs; username = "jrt"; inherit stateVersion; };
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        home-manager.users.jrt = import ../home-manager;
      }
      mixins/cli
      mixins/gui
      mixins/backups
      mixins/impermanence
      mixins/laptop
      mixins/secureboot
      mixins/server
      mixins/virt
    ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  boot.kernelPackages = pkgs.linuxPackages_latest;
  # boot.kernelPackages = pkgs.linuxPackages_testing;
  boot.initrd.systemd.enable = true;

  hardware.enableAllFirmware = true;
  nixpkgs.config.allowUnfree = true;

  boot.initrd.verbose = false;
  boot.consoleLogLevel = 0;
  boot.kernelParams = [
      "quiet"
      "splash"
      "loglevel=3"
      "rd.systemd.show_status=false"
      "rd.udev.log_level=3"
      "udev.log_priority=3"
  ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "thunderbolt" "nvme" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  networking.useDHCP = lib.mkDefault true;
  networking.networkmanager.enable = true;

  nixpkgs.hostPlatform = lib.mkDefault platform;
  # Set your time zone.
  powerManagement = {
    enable = true;
  };

  i18n.defaultLocale = "en_US.UTF-8";
  console = {
     font = "Lat2-Terminus16";
     keyMap = "us";
  };

  security.rtkit.enable = true;

  users.users.jrt = {
     isNormalUser = true;
     extraGroups = [ "wheel" "tss" "input" "audio" "video" "ydotool" "libvirtd" ]; # Enable ‘sudo’ for the user.
     packages = with pkgs; [
       firefox
       tree
     ];
     hashedPassword = "$6$JvSJ6iVd3.DRDc8e$lv.YEJaRy73l9RsiE6hmZm61Q0hH.cHo.QsFSGUsEjaS3n0EDnpzEqbaj6cNrYaw/9qnQLNo9TZ7RmipgBebw/";
     description = "Jacob Root";
     uid = 1001;
     shell = pkgs.zsh;
  };

  services.fwupd.enable = true;

  services.dbus.implementation = "broker";
  system.stateVersion = stateVersion; # Did you read the comment?
}
