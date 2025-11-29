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
    # Flake inputs
    inputs.hyprland.nixosModules.default
    inputs.impermanence.nixosModules.impermanence
    inputs.lanzaboote.nixosModules.lanzaboote
    inputs.chaotic.nixosModules.default
    inputs.home-manager.nixosModules.home-manager

    # Host configuration
    ./${hostname}

    # Home-manager configuration
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

    # System modules (unconditionally enabled)
    modules/system/impermanence.nix
    modules/system/kernel.nix
    modules/system/locale.nix
    modules/system/networking.nix
    modules/system/secureboot.nix
    modules/system/ydotool.nix

    # System modules (conditionally enabled)
    modules/system/cli.nix
    modules/system/developer-tools.nix
    modules/system/laptop.nix
    modules/system/remote-access.nix
    modules/system/virt.nix

    # Optional apps
    modules/apps/claude-code.nix
    modules/apps/jellyfin.nix
    modules/apps/sabnzbd.nix
  ];

  # Enable conditional system modules
  modules.system.cli.enable = lib.mkDefault true;
  modules.system.developer-tools.enable = lib.mkDefault true;
  modules.system.laptop.enable = lib.mkDefault false; # Only enable on laptops
  modules.system.remote-access.enable = lib.mkDefault true;
  modules.system.virt.enable = lib.mkDefault true;

  # Optional service apps (disabled by default)
  modules.apps.jellyfin.enable = lib.mkDefault false;
  modules.apps.sabnzbd.enable = lib.mkDefault false;

  # Nix settings
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    substituters = [ "https://hyprland.cachix.org" ];
    trusted-public-keys = [ "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc=" ];
  };

  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 30d";
  };

  # Don't garbage collect flake inputs
  system.extraDependencies =
    let
      collectFlakeInputs =
        input:
        [ input ] ++ builtins.concatMap collectFlakeInputs (builtins.attrValues (input.inputs or { }));
    in
    builtins.concatMap collectFlakeInputs (builtins.attrValues inputs);

  # Nixpkgs configuration
  nixpkgs.config.allowUnfree = true;
  nixpkgs.overlays = builtins.attrValues outputs.overlays;
  nixpkgs.hostPlatform = lib.mkDefault platform;

  # Power management
  powerManagement.enable = true;

  # Security
  security.rtkit.enable = true;
  security.sudo.extraConfig = ''
    Defaults        timestamp_timeout=-1
  '';

  #systemd.coredump.enable = false;
  #boot.kernel.sysctl."kernel.core_pattern" = "|/bin/false";

  # Users
  users.users.root.hashedPassword = "$y$j9T$/mXrIMQE7/SDmS9f9MyMB0$ouFzDiwIZFC0kHhh3kygGmpthEa86ztWnVcc3iFEV5.";

  users.users.jrt = {
    isNormalUser = true;
    description = "Jacob Root";
    uid = 1001;
    shell = pkgs.zsh;
    hashedPassword = "$6$JvSJ6iVd3.DRDc8e$lv.YEJaRy73l9RsiE6hmZm61Q0hH.cHo.QsFSGUsEjaS3n0EDnpzEqbaj6cNrYaw/9qnQLNo9TZ7RmipgBebw/";
    extraGroups = [
      "wheel"
      "tss"
      "input"
      "audio"
      "video"
      "libvirtd"
      "networkmanager"
    ];
    packages = with pkgs; [
      tree
    ];
  };

  # Services
  services.fwupd.enable = true;
  services.dbus.implementation = "broker";

  system.stateVersion = stateVersion;
}
