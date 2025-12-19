# NVIDIA graphics configuration
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.system.hardware.nvidia;
in
{
  options.modules.system.hardware.nvidia = {
    enable = lib.mkEnableOption "NVIDIA graphics drivers";

    openDrivers = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Use open-source NVIDIA drivers";
    };

    useBeta = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use beta NVIDIA drivers";
    };
  };

  config = lib.mkIf cfg.enable {
    services.xserver.videoDrivers = [ "nvidia" ];

    hardware.nvidia.open = cfg.openDrivers;
    hardware.nvidia.package =
      if cfg.useBeta then
        config.boot.kernelPackages.nvidiaPackages.beta
      else
        config.boot.kernelPackages.nvidiaPackages.stable;
    hardware.nvidia.modesetting.enable = true;
  };
}
