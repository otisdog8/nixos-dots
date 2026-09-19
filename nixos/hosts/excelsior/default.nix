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

    # Physical layout, left to right: ASUS OLED, KTC, then the two Dells
    # stacked (4DGM884 bottom, GCGM884 top). All 4K@scale 1 at each panel's
    # max refresh (highres alone picks the preferred rate), so each column
    # is 3840 wide; the stacked pair keeps everything in positive coords by
    # putting the main row at y=2160 and the top Dell at y=0. desc: matching
    # keeps the layout stable if connectors move.
    desktop.full.hyprland = {
      monitors = [
        {
          output = "desc:ASUSTek COMPUTER INC PG32UCDM3 W4LMAV007023";
          mode = "3840x2160@240";
          position = "0x2160";
          scale = 1;
          bitdepth = 8;
        }
        {
          output = "desc:Shenzhen KTC Technology Group H32P22P";
          mode = "3840x2160@165";
          position = "3840x2160";
          scale = 1;
          bitdepth = 8;
        }
        {
          output = "desc:Dell Inc. DELL U2725QE 4DGM884";
          mode = "3840x2160@120";
          position = "7680x2160";
          scale = 1;
          bitdepth = 8;
        }
        {
          output = "desc:Dell Inc. DELL U2725QE GCGM884";
          mode = "3840x2160@120";
          position = "7680x0";
          scale = 1;
          bitdepth = 8;
        }
      ];

      # The ASUS is a QD-OLED: power it off after 2.5 min idle (global dpms
      # stays at 450s) so an idle desktop doesn't keep the panel lit.
      hypridle.oledMonitors = [ "desc:ASUSTek COMPUTER INC PG32UCDM3 W4LMAV007023" ];
    };

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
