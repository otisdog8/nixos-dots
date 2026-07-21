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
  networking.hostName = "excelsior";
  time.timeZone = "America/Los_Angeles";

  boot.supportedFilesystems = [ "btrfs" ];
  boot.blacklistedKernelModules = [ "amdgpu" ];
  #boot.kernelPackages = lib.mkOverride 50 pkgs.linuxPackages_6_18;

  imports = [
    ./disks.nix
    ./backups.nix
    inputs.sops-nix.nixosModules.sops

    # Hardware
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    inputs.nixos-hardware.nixosModules.common-pc
    inputs.nixos-hardware.nixosModules.common-pc-ssd

    # Desktop environment
    ../../modules/desktop/full

    # System modules
    ../../modules/system/hardware/nvidia.nix
    ../../modules/bundles/gaming.nix
  ];

  # Host-wide sops-nix base config; per-secret declarations live next to their
  # consumers (e.g. ./backups.nix). Decryption uses the SSH host ed25519 key,
  # persisted under /persist by remote-access.nix (enabled by default).
  sops = {
    defaultSopsFile = ./secrets/excelsior.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  };

  # Enable full desktop environment
  modules = {
    desktop.full.enable = true;

    # Hardening baseline — workstation profile keeps userns on for
    # Steam/Chromium sandboxing and skips the linux-hardened kernel so
    # NVIDIA DKMS keeps working.
    system.hardening = {
      enable = true;
      profile = "workstation";
      blacklistAfAlg = true;
    };

    system.pcr-verification = {
      enable = true;
      expectedPcr15 = "a764815e35045166ee14a593919eac6b4538a128ac8d2118f90febe9f6001070";
    };

    # Enable NVIDIA drivers (beta)
    system.hardware.nvidia = {
      enable = true;
      useBeta = false;
      # Single-GPU host: keep videoDrivers exactly ["nvidia"] (the module now
      # merges by default to support multi-GPU/roaming hosts).
      forceVideoDrivers = true;
    };

    bundles.gaming.enable = true;
  };

  # WiFi workarounds
  # networking.networkmanager.wifi.backend = "iwd";

  programs.captive-browser.enable = true;

  systemd.services.connect-wifi = {
    script = ''
      for _ in $(seq 1 30); do
        ${pkgs.networkmanager}/bin/nmcli -t connection show >/dev/null 2>&1 && break
        sleep 1
      done
      # Pin secret storage to the .nmconnection file; without this NM falls back
      # to a user-agent which is absent at boot. Idempotent on each start.
      ${pkgs.networkmanager}/bin/nmcli connection modify "Rim And Job 1" \
        802-11-wireless-security.psk-flags 0
      ${pkgs.networkmanager}/bin/nmcli connection up id "Rim And Job 1"
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    wantedBy = [ "multi-user.target" ];
    after = [
      "NetworkManager.service"
      #"iwd.service"
    ];
    wants = [ "NetworkManager.service" ];
    restartIfChanged = false;
  };

  systemd.services.network-restarter = {
    description = "Check internet connectivity and restart NetworkManager if down";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      User = "root";
      Restart = "on-failure";
      RestartSec = "10s";
    };
    script = ''
      echo "Starting network-restarter service..."

      while true; do
        echo "Checking network connectivity..."
        if ! ${pkgs.iputils}/bin/ping -c1 -W1 1.1.1.1 &>/dev/null && \
           ! ${pkgs.iputils}/bin/ping -c1 -W1 8.8.8.8 &>/dev/null && \
           ! ${pkgs.iputils}/bin/ping -c1 -W1 google.com &>/dev/null; then
          echo "Network connectivity check failed. Restarting NetworkManager.service..."
          ${pkgs.systemd}/bin/systemctl restart NetworkManager.service
          echo "NetworkManager.service restart requested."
          ${pkgs.coreutils}/bin/sleep 15
        else
          echo "Network connectivity OK."
        fi

        echo "Sleeping for 300 seconds..."
        ${pkgs.coreutils}/bin/sleep 300
      done
    '';
  };
}
