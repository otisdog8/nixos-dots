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
  networking.hostName = "recusant";
  time.timeZone = "America/Los_Angeles";

  boot.supportedFilesystems = [ "btrfs" ];

  imports = [
    ./disks.nix
    ./minecraft.nix
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    inputs.nixos-hardware.nixosModules.common-pc
    inputs.nixos-hardware.nixosModules.common-pc-ssd
  ];

  services.xserver.videoDrivers = [ "modesetting" ];
  hardware.graphics.extraPackages32 = with pkgs.pkgsi686Linux; [ intel-media-driver ];
  hardware.graphics = { # hardware.graphics since NixOS 24.11
    enable = true;
    extraPackages = with pkgs; [
      libvdpau-va-gl
      intel-media-driver
      intel-compute-runtime
      vpl-gpu-rt          # for newer GPUs on NixOS >24.05 or unstable
    ];
  };

  boot.consoleLogLevel = 0; 


  services.nfs.server.enable = true;
  services.nfs.server.exports = ''
    /export/k8s  100.0.0.0/8(rw,nohide,insecure,no_subtree_check,all_squash,anonuid=1001,anongid=1001,no_root_squash)
  '';

  networking.firewall.allowedTCPPorts = [ 2049 ];
}
