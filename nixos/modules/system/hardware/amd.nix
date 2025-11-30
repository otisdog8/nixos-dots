# AMD GPU configuration
{ config, lib, pkgs, ... }:
let
  cfg = config.modules.system.hardware.amd;
in
{
  options.modules.system.hardware.amd = {
    enable = lib.mkEnableOption "AMD GPU drivers";
  };

  config = lib.mkIf cfg.enable {
    boot.initrd.kernelModules = [ "amdgpu" ];
    services.xserver.videoDrivers = [ "amdgpu" ];
  };
}
