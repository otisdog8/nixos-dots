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

  imports = [
    ./disks.nix
    ./secrets.nix

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

  # Enable full desktop environment
  modules.desktop.full.enable = true;

  # Enable NVIDIA drivers (beta)
  modules.system.hardware.nvidia = {
    enable = true;
    useBeta = true;
  };

  # WiFi workarounds
  networking.networkmanager.wifi.backend = "iwd";

  modules.bundles.gaming.enable = true;

  systemd.services.connect-wifi = {
    script = ''
      sleep 10
      ${pkgs.networkmanager}/bin/nmcli device connect wlan0
    '';
    serviceConfig = {
      Type = "oneshot";
      User = "jrt";
    };
    wantedBy = [ "multi-user.target" ];
    after = [
      "NetworkManager.service"
      "iwd.service"
      "multi-user.target"
    ];
  };

  systemd.services.network-restarter = {
    description = "Check internet connectivity and restart iwd service if down";
    after = [
      "network-online.target"
      "iwd.service"
    ];
    wants = [
      "network-online.target"
      "iwd.service"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      User = "root";
      Restart = "on-failure";
      RestartSec = "10s";
    };
    script = ''
      #!${pkgs.runtimeShell}
      set -e

      echo "Starting network-restarter service..."

      while true; do
        echo "Checking network connectivity..."
        if ! ${pkgs.iputils}/bin/ping -c1 -W1 1.1.1.1 &>/dev/null && \
           ! ${pkgs.iputils}/bin/ping -c1 -W1 8.8.8.8 &>/dev/null && \
           ! ${pkgs.iputils}/bin/ping -c1 -W1 google.com &>/dev/null; then
          echo "Network connectivity check failed. Restarting iwd.service..."
          ${pkgs.systemd}/bin/systemctl restart iwd.service
          echo "iwd.service restart requested."
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
