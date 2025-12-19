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
  networking.hostName = "carrack";
  time.timeZone = "America/Los_Angeles";

  boot = {
    supportedFilesystems = [ "btrfs" ];
    initrd = {
      supportedFilesystems = [ "nfs" ];
      kernelModules = [ "nfs" ];
    };
  };

  imports = [
    ./disks.nix

    # Hardware
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    inputs.nixos-hardware.nixosModules.common-gpu-amd
    inputs.nixos-hardware.nixosModules.common-pc
    inputs.nixos-hardware.nixosModules.common-pc-ssd

    # Desktop environment
    ../../modules/desktop/full

    # System modules
    ../../modules/system/hardware/amd.nix
    ../../modules/system/k3s
  ];

  # Enable full desktop environment
  modules.desktop.full.enable = true;

  # Enable AMD GPU
  modules.system.hardware.amd.enable = true;

  # K3s cluster node
  modules.system.k3s = {
    enable = true;
    serverAddr = "https://100.126.30.73:6443";
    extraFlags = [
      "--bind-address=100.103.225.29"
      "--node-ip=100.103.225.29"
      "--advertise-address=100.103.225.29"
    ];
  };

  networking.firewall.enable = lib.mkForce false;
}
