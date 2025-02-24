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
