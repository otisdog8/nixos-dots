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
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    inputs.nixos-hardware.nixosModules.common-pc
    inputs.nixos-hardware.nixosModules.common-pc-ssd
  ];

  systemd.services.connect-wifi = {
    script = ''
      sleep 10
      ${pkgs.networkmanager}/bin/nmcli device connect wlan0
    '';
    serviceConfig = {
      Type = "oneshot";
      User = "jrt";
    };

    wantedBy = [
      "multi-user.target"
    ];

    after = [
      "NetworkManager.service"
      "iwd.service"
      "multi-user.target"
    ];
  };

  systemd.services.network-restarter = {
    description = "Check internet connectivity and restart iwd service if down";

    # Dependencies:
    # Ensure this service starts after network target and iwd itself.
    # 'network-online.target' is a better target than just 'network.target'
    # as it waits for a configured network connection to be actually up.
    after = [
      "network-online.target"
      "iwd.service"
    ];
    wants = [
      "network-online.target"
      "iwd.service"
    ];

    # Start this service during normal system boot
    wantedBy = [ "multi-user.target" ];

    # Service configuration
    serviceConfig = {
      # Type=simple means the script itself is the main process
      Type = "simple";

      # IMPORTANT: Run as root user.
      # This is necessary to grant permission for the script's 'systemctl restart iwd' command
      # to succeed. Systemd/Polkit usually allows root to manage services.
      User = "root";

      # Restart the service itself if it fails for some reason
      Restart = "on-failure";
      RestartSec = "10s"; # Wait 10 seconds before restarting this service if it crashes

      # Optional: Limit resource usage if desired
      # CPUQuota="5%";
      # MemoryMax="64M";
    };

    # The script to execute
    # We use absolute paths via pkgs interpolation for robustness
    script = ''
      #!${pkgs.runtimeShell}
      set -e # Exit immediately if a command exits with a non-zero status.

      echo "Starting network-restarter service..."

      while true; do
        echo "Checking network connectivity..."
        # Check connectivity to multiple reliable targets
        # The '!' negates the exit status. If ping fails (exit status != 0), !ping is true.
        # We proceed to restart iwd only if *all* pings fail.
        if ! ${pkgs.iputils}/bin/ping -c1 -W1 1.1.1.1 &>/dev/null && \
           ! ${pkgs.iputils}/bin/ping -c1 -W1 8.8.8.8 &>/dev/null && \
           ! ${pkgs.iputils}/bin/ping -c1 -W1 google.com &>/dev/null; then
          # All pings failed
          echo "Network connectivity check failed. Restarting iwd.service..."
          # Use systemctl to restart the iwd service.
          # Running as root (defined in serviceConfig) grants permission.
          ${pkgs.systemd}/bin/systemctl restart iwd.service
          echo "iwd.service restart requested."
          # Optional: Wait a bit after restarting before sleeping for the main interval
          ${pkgs.coreutils}/bin/sleep 15
        else
          # At least one ping succeeded
          echo "Network connectivity OK."
        fi

        # Wait for 5 minutes (300 seconds) before the next check
        echo "Sleeping for 300 seconds..."
        ${pkgs.coreutils}/bin/sleep 300
      done
    '';
  };

  services.xserver.videoDrivers = [ "nvidia" ];
  networking.networkmanager.wifi.backend = "iwd";

  hardware.nvidia.open = true;
  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.beta;
  hardware.nvidia.prime = {
    amdgpuBusId = "PCI:71:0:0";
    nvidiaBusId = "PCI:1:0:0";
  };
  hardware.nvidia.modesetting.enable = true;
}
