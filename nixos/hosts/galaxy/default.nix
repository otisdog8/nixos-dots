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
    ./backups.nix
    ./llm.nix
    inputs.sops-nix.nixosModules.sops

    # Hardware
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    inputs.nixos-hardware.nixosModules.common-pc
    inputs.nixos-hardware.nixosModules.common-pc-ssd

    # Desktop environment
    ../../modules/desktop/full

    # Gaming bundle
    ../../modules/bundles/gaming.nix

    # System modules
    ../../modules/system/hardware/nvidia.nix
  ];

  # Host-wide sops-nix base config; per-secret declarations live next to their
  # consumers (e.g. ./backups.nix). Decryption uses the SSH host ed25519 key,
  # persisted under /persist by remote-access.nix (enabled by default).
  sops = {
    defaultSopsFile = ./secrets/galaxy.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  };

  # Enable full desktop environment
  # This automatically enables: browsers, communication, productivity, media bundles
  # along with shared desktop modules (base, fonts, xdg, theming, printing)
  modules = {
    # The agents' shared sandbox is a VM here (`claude-agents`, `codex-agents`,
    # and the other agents' plain commands).
    sandbox.agents.mode = "vm";

    # App sandboxes see ONLY the display GPU (4090). With both cards visible,
    # chromium/ANGLE picks a device by enumeration order and can land buffer
    # allocation on the compute-only 5070 while the compositor/window is on the
    # 4090 — NVIDIA rejects every cross-GPU dmabuf import (EGL_BAD_ALLOC /
    # VK_ERROR_OUT_OF_DEVICE_MEMORY → context-lost loop, black window; hit by
    # tetrio 2026-07). The 5070 is llama.cpp's card; no sandboxed GUI app needs
    # it. Node map (verified via /dev/dri/by-path + nvidia-smi Minor Number;
    # simple-framebuffer scrambled card numbering, so DRM order ≠ PCI order):
    #   4090 = pci 01:00.0 → card1, renderD128, /dev/nvidia0
    #   5070 = pci 05:00.0 → card0, renderD129, /dev/nvidia1
    # Literal names, not by-path: binds are try-binds, so if a future boot
    # reshuffles numbering the symptom returns (black tetrio) rather than
    # breaking anything — re-verify the map then.
    sandbox.gpuDevices = [
      "/dev/dri/card1"
      "/dev/dri/renderD128"
      "/dev/nvidia0"
      "/dev/nvidiactl"
      "/dev/nvidia-modeset"
      "/dev/nvidia-uvm"
      "/dev/nvidia-uvm-tools"
    ];

    desktop.full.enable = true;

    # Enable gaming bundle
    bundles.gaming.enable = true;

    # Ship kernel logs to the netconsole collector (arquitens). Wired ethernet
    # on the collector's LAN; if the USB NIC's driver turns out to lack netpoll
    # support, the netconsole modprobe fails and keeps retrying (check
    # `systemctl status netconsole-sender` after first rebuild).
    system.netconsole.enable = true;

    # Hardening baseline (pilot host) — workstation profile keeps userns on
    # for Steam/Chromium sandboxing and skips the linux-hardened kernel so
    # NVIDIA DKMS keeps working.
    system.hardening = {
      enable = true;
      profile = "workstation";
      blacklistAfAlg = true;
    };

    # Bootstrap pass: measurement only, no enforcement. Capture
    # PCR 15 on a known-good boot with
    # `systemd-analyze pcrs 15 --json=short`, then set expectedPcr15.
    system.pcr-verification = {
      enable = true;
      expectedPcr15 = "440e25ba3289b1461cdd57ea062e4e43f714c5725863f1498b5b96256781647b";
    };

    # Enable NVIDIA drivers (beta)
    system.hardware.nvidia = {
      enable = true;
      useBeta = false;
      # Single-GPU host: keep videoDrivers exactly ["nvidia"] (the module now
      # merges by default to support multi-GPU/roaming hosts).
      forceVideoDrivers = true;
    };
  };
}
