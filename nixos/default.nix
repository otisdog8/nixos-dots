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
    inputs.nixvim.nixosModules.default

    # Host configuration
    ./hosts/${hostname}

    # System modules (unconditionally enabled)
    modules/system/impermanence.nix
    modules/system/sandbox.nix
    modules/system/kernel.nix
    modules/system/locale.nix
    modules/system/networking.nix
    modules/system/secureboot.nix
    modules/system/ydotool.nix

    # System modules (conditionally enabled)
    modules/system/cli.nix
    modules/system/developer-tools.nix
    modules/system/dns.nix
    modules/system/hardening.nix
    modules/system/laptop.nix
    modules/system/pcr-verification.nix
    modules/system/remote-access.nix
    modules/system/virt.nix
    modules/system/zswap.nix
    modules/system/hardware/openrazer.nix

    # Optional apps
    modules/apps/codex.nix
    modules/apps/gemini-cli.nix
    modules/apps/gsd.nix
    modules/apps/opencode.nix
    modules/apps/claude-code.nix
    modules/apps/ccusage.nix
    modules/apps/agent-auth-client.nix
    modules/apps/hermes-agents.nix
    modules/apps/sandbox-shell.nix
    modules/apps/nixvim.nix
    modules/apps/jellyfin.nix
    modules/apps/sabnzbd.nix
  ];

  # Enable conditional system modules and optional service apps
  modules = {
    system = {
      cli.enable = lib.mkDefault true;
      developer-tools.enable = lib.mkDefault true;
      dns.enable = lib.mkDefault true;
      hardening.enable = lib.mkDefault false; # Opt-in per host
      laptop.enable = lib.mkDefault false; # Only enable on laptops
      pcr-verification.enable = lib.mkDefault false; # Opt-in per host
      secureboot.enable = lib.mkDefault true; # Opt-out per host (liveusb disables)
      remote-access.enable = lib.mkDefault true;
      virt.enable = lib.mkDefault true;
      hardware.openrazer.enable = lib.mkDefault false;
    };
    apps = {
      jellyfin.enable = lib.mkDefault false;
      sabnzbd.enable = lib.mkDefault false;
      agent-auth-client.enable = lib.mkDefault true;
    };
  };

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

  # Home-manager configuration
  home-manager = {
    extraSpecialArgs = {
      inherit inputs;
      username = "jrt";
      inherit stateVersion;
    };
    useGlobalPkgs = true;
    useUserPackages = true;
    users.jrt = import ../home-manager;
  };

  # Nixpkgs configuration
  nixpkgs = {
    config.allowUnfree = true;
    overlays = builtins.attrValues outputs.overlays ++ [ inputs.nix-minecraft.overlay ];
    hostPlatform = lib.mkDefault platform;
  };

  # Power management
  powerManagement.enable = true;

  # Security
  security.rtkit.enable = true;
  # sudo tickets expire after 1h (was -1 = never expire, so a single sudo left the
  # session root-capable indefinitely). 60 min balances convenience vs. a stolen
  # ticket's blast radius.
  security.sudo.extraConfig = ''
    Defaults        timestamp_timeout=60
  '';

  #systemd.coredump.enable = false;
  #boot.kernel.sysctl."kernel.core_pattern" = "|/bin/false";

  # Users — fully declarative. mutableUsers=false means /etc/{passwd,shadow,group}
  # are rebuilt from this config on every activation: `useradd`/`passwd` changes
  # (e.g. an attacker with transient root adding a login) can't stick, and there
  # is no drift. Every login user must therefore have a declarative password;
  # jrt and root both do below. Override per-host with lib.mkForce if ever needed.
  users.mutableUsers = false;

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
      # NB: no "input". Membership grants raw read/write on /dev/input/* (keylogging
      # + input injection, bypassing logind's per-session device ACLs). Hyprland
      # gets input via logind/seatd seat management on the active session, not this
      # group, so jrt doesn't need it. Apps that genuinely need /dev/input (e.g.
      # prismlauncher) get it on their own dedicated uid, not via jrt.
      "audio"
      "video"
      "kvm"
      # NB: no "libvirtd". A system-mode libvirt r/w connection is ≈ a root shell
      # (define a domain with any host disk / <qemu:commandline> and start it), so
      # the group is effectively root and would undercut the dedicated-uid sandbox
      # threat model. qemu.runAsRoot = false (virt.nix) contains the guest, not the
      # client. Manage system VMs with sudo, or a rootless qemu:///session.
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
