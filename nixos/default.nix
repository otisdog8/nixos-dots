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
  imports = [
    # Include the results of the hardwae scan.
    inputs.hyprland.nixosModules.default
    inputs.impermanence.nixosModules.impermanence
    inputs.lanzaboote.nixosModules.lanzaboote
    inputs.chaotic.nixosModules.default # OUR DEFAULT MODULE
    inputs.home-manager.nixosModules.home-manager
    ./${hostname}
    {
      home-manager.extraSpecialArgs = {
        inherit inputs;
        username = "jrt";
        inherit stateVersion;
      };
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
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  nix.settings = {
    substituters = ["https://hyprland.cachix.org"];
    trusted-public-keys = ["hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="];
  };

  systemd.coredump.enable = false;
  boot.kernel.sysctl."kernel.core_pattern" = "|/bin/false";
  boot.kernel.sysctl."fs.suid_dumpable" = 0;

  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 30d";
  };
  #boot.kernelPackages = pkgs.linuxPackagesFor (pkgs.linux_6_13.override {
  #  argsOverride = rec {
  #    src = pkgs.fetchurl {
  #          url = "mirror://kernel/linux/kernel/v6.x/linux-${version}.tar.xz";
  #          sha256 = "sha256-KD7LB4Tz+8Ft2CL7HZZC4jDsdRXtM/Eg5VG4OfNV5uI=";
  #    };
  #    version = "6.13.5";
  #    modDirVersion = "6.13.5";
  #    };
  #});
  nixpkgs = {
    overlays = [
      outputs.overlays.older-packages
      (final: prev: {
        linux-firmware = prev.linux-firmware.overrideAttrs (old: {
          postInstall = ''
            cp ${../files/ibt-0190-0291-usb.sfi} $out/lib/firmware/intel/ibt-0190-0291-usb.sfi
          '';
        });
      })

    ];

  };
  # boot.kernelPackages = pkgs.linuxPackagesFor (pkgs.linux_6_13.override { argsOverride = { version = "6.13.5"; }; });
  #boot.kernelPackages = pkgs.linuxKernel.packages.linux_6_13_5;
  # boot.kernelPackages = pkgs.older.linuxKernel.packages.linux_6_13;
  # boot.kernelPackages = pkgs.linuxPackages_testing;
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.initrd.systemd.enable = true;

  hardware.enableAllFirmware = true;
  hardware.firmware = [
    pkgs.firmwareLinuxNonfree
    pkgs.linux-firmware
    pkgs.sof-firmware
    pkgs.alsa-firmware
  ];
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

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "thunderbolt"
    "nvme"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  networking.useDHCP = lib.mkDefault true;
  networking.networkmanager = {
    enable = true;
    wifi.scanRandMacAddress = false;
  };

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

  # Create the 'hidraw' group if it doesn't exist.
  users.groups.hidraw = { };

  # Provide custom udev rules.
  services.udev.extraRules = ''
    KERNEL=="hidraw*", SUBSYSTEM=="hidraw", GROUP="hidraw", MODE="0660"
  '';

  # Don't garbage collect flakes sources
  system.extraDependencies =
    let
      collectFlakeInputs =
        input:
        [ input ] ++ builtins.concatMap collectFlakeInputs (builtins.attrValues (input.inputs or { }));
    in
    builtins.concatMap collectFlakeInputs (builtins.attrValues inputs);

  users.users.jrt = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "tss"
      "input"
      "audio"
      "video"
      "ydotool"
      "libvirtd"
      "hidraw"
      "networkmanager"
    ]; # Enable ‘sudo’ for the user.
    packages = with pkgs; [
      firefox
      tree
    ];
    hashedPassword = "$6$JvSJ6iVd3.DRDc8e$lv.YEJaRy73l9RsiE6hmZm61Q0hH.cHo.QsFSGUsEjaS3n0EDnpzEqbaj6cNrYaw/9qnQLNo9TZ7RmipgBebw/";
    description = "Jacob Root";
    uid = 1001;
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICPtgHM9vEd6NR70wKznoP/HE3aCrud/9rx/2Lu16Dh4 jrt@excelsior"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKrESH5ZwJ9UprxxlPHlwMTLZtNiFysHR+5CHcTA63+a jrt@constitution"
    ];
  };

  security.sudo.extraConfig = ''
    Defaults        timestamp_timeout=-1
  '';

  services.fwupd.enable = true;

  services.dbus.implementation = "broker";
  system.stateVersion = stateVersion; # Did you read the comment?
}
