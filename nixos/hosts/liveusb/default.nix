# Portable "liveusb" host: a roaming, encrypted, personal Hyprland workstation on
# a USB stick. Minted with `nix run .#mint-usb -- /dev/sdX`.
#
# Boot menu (systemd-boot):
#   - default : persistent install (LUKS btrfs + impermanence, state survives)
#   - live    : ephemeral, single shared tmpfs backs / and every persist subvol
#
# Differences from the other hosts:
#   - Secure Boot / lanzaboote / PCR are OFF (machine-specific; a roaming stick
#     can't use TPM/PCR), plain systemd-boot instead.
#   - One universal GPU stack: open Intel/AMD + proprietary NVIDIA in the base,
#     so the same entry drives any machine the stick is plugged into.
#   - LTS kernel (decouples the build from NVIDIA-vs-bleeding-edge-kernel breakage).
{
  inputs,
  lib,
  pkgs,
  ...
}:
{
  networking.hostName = "liveusb";
  time.timeZone = "America/Los_Angeles";

  boot.supportedFilesystems = [ "btrfs" ];

  imports = [
    inputs.disko.nixosModules.disko
    ./disko.nix

    # Generic portable hardware only (no per-machine nixos-hardware module).
    inputs.nixos-hardware.nixosModules.common-pc
    inputs.nixos-hardware.nixosModules.common-pc-ssd

    # Desktop environment + proprietary NVIDIA (merges with the open drivers below).
    ../../modules/desktop/full
    ../../modules/system/hardware/nvidia.nix
  ];

  # ---- Bootloader: plain systemd-boot, Secure Boot / PCR off ----
  modules.system.secureboot.enable = false;
  modules.system.pcr-verification.enable = false;

  # secureboot.nix used to mkForce systemd-boot off; with it disabled we must
  # enable systemd-boot ourselves. canTouchEfiVariables = false so a roaming
  # stick boots from its removable fallback path without writing each host's NVRAM.
  boot.loader.systemd-boot.enable = lib.mkForce true;
  boot.loader.efi.canTouchEfiVariables = false;

  # ---- Feature enables ----
  modules = {
    desktop.full.enable = true;

    # The USB's LUKS mapper is "cryptliveusb" (see disko.nix) to avoid colliding
    # with a minting host's own /dev/mapper/luks. Point the rollback service at it.
    system.impermanence.rollbackDevice = "/dev/mapper/cryptliveusb";

    system.hardening = {
      enable = true;
      profile = "workstation";
      blacklistAfAlg = true;
    };

    # Harmless on desktops (battery thresholds no-op without a battery); gives
    # TLP/thermald/upower for the laptops this stick will roam onto.
    system.laptop.enable = true;

    # Proprietary NVIDIA in the base. forceVideoDrivers stays false so the module
    # merges "nvidia" with the open list below rather than replacing it.
    system.hardware.nvidia = {
      enable = true;
      openDrivers = false; # proprietary kernel module (widest GPU-generation support)
    };
  };

  # captive-browser is configured in networking.nix; the browsers bundle (via
  # desktop.full) supplies the chromium it launches.
  programs.captive-browser.enable = true;

  # ---- Universal open GPU (Intel + AMD); NVIDIA added by the module above ----
  # Effective videoDrivers merge: [ "modesetting" "amdgpu" "nvidia" ]. On
  # AMD/Intel-only machines the nvidia modules load inert (no GBM/GLX env vars to
  # break the iGPU compositor); on NVIDIA machines the proprietary driver binds.
  services.xserver.videoDrivers = [
    "modesetting"
    "amdgpu"
  ];

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      mesa
      intel-media-driver
      intel-vaapi-driver
      libva-vdpau-driver
      libvdpau-va-gl
      vpl-gpu-rt
      vulkan-loader
    ];
    extraPackages32 = with pkgs.pkgsi686Linux; [
      mesa
      intel-media-driver
      libva-vdpau-driver
    ];
  };

  # ---- LTS kernel: keep the whole-stick build off the NVIDIA-vs-_latest cliff ----
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages;

  # ---- Swap: zram first tier, random-key encrypted partition (disko) second ----
  zramSwap = {
    enable = true;
    priority = 100;
    memoryPercent = 50;
  };
  boot.resumeDevice = lib.mkForce ""; # random-key swap => never hibernate

  # ---- neededForBoot parity with the other hosts (disko entries merge) ----
  # Plain assignments (not mkForce) so the `live` specialisation's mkForce wins.
  fileSystems = {
    "/mnt/btrfs_root".neededForBoot = true;
    "/nix".neededForBoot = true;
    "/persist".neededForBoot = true;
    "/large".neededForBoot = true;
    "/cache".neededForBoot = true;
    "/dots".neededForBoot = true;
  };

  # =====================================================================
  # specialisation.live : ephemeral mode
  # Default boot = persistent (impermanence rollback wipes the `root` subvol via
  # the initrd service; the persist subvols are real btrfs and survive). The
  # `live` entry instead backs / AND every persist subvol with tmpfs and disables
  # rollback. impermanence stays enabled and still binds persisted dirs out of
  # /persist — but /persist is now RAM, so everything is fully volatile.
  #
  # These are separate tmpfs mounts rather than one shared tmpfs + binds because
  # impermanence requires its persist filesystems to have neededForBoot = true
  # (mounted in initrd), and a bind's source dir can't exist that early. tmpfs
  # `size=` is a cap, not a reservation, so the mounts still draw from one shared
  # physical pool. /nix and /boot stay real (inherited from disko).
  #
  # Overcommit: tmpfs pages swap out, so the caps are set to an absolute 32G —
  # above physical RAM on these machines — and the overflow spills into zram + the
  # 32G encrypted swap partition. A tmpfs cap that exceeds RAM + total swap would
  # deadlock when filled (the OOM killer can't reclaim tmpfs pages — see the kernel
  # tmpfs docs); matching the cap (32G) to the swap size keeps it <= RAM + swap on
  # ANY machine (RAM + 32G >= 32G always), so a full tmpfs degrades to a graceful
  # ENOSPC rather than a hang. tmpfs costs no disk; it lives in RAM/swap.
  # =====================================================================
  specialisation.live.configuration = {
    system.nixos.tags = [ "live" ];

    # No btrfs `root` subvol to roll back when / is tmpfs.
    boot.initrd.systemd.services.rollback.enable = lib.mkForce false;

    fileSystems =
      let
        tmp =
          {
            neededForBoot ? false,
            size ? "32G", # matches the swap partition; overflow goes to swap
          }:
          lib.mkForce {
            device = "tmpfs";
            fsType = "tmpfs";
            inherit neededForBoot;
            options = [
              "mode=0755"
              "size=${size}"
            ];
          };
      in
      {
        "/" = tmp { };
        # Persistence targets: impermanence asserts neededForBoot = true.
        "/persist" = tmp { neededForBoot = true; };
        "/large" = tmp { neededForBoot = true; };
        "/cache" = tmp { neededForBoot = true; };
        # Not persistence targets; ephemeral all the same.
        "/dots" = tmp { };
        "/mnt/btrfs_root" = tmp { size = "1G"; };
      };
  };
}
