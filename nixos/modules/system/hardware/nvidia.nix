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

    forceVideoDrivers = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        When true, force services.xserver.videoDrivers to exactly [ "nvidia" ]
        (single-GPU desktops). When false (default), only contribute "nvidia" and
        let the NixOS module system merge it with any open drivers the host
        declares (e.g. a roaming USB with modesetting + amdgpu + nvidia).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.xserver.videoDrivers =
      if cfg.forceVideoDrivers then lib.mkForce [ "nvidia" ] else [ "nvidia" ];

    hardware.nvidia = {
      open = cfg.openDrivers;
      package =
        if cfg.useBeta then
          config.boot.kernelPackages.nvidiaPackages.beta
        else
          config.boot.kernelPackages.nvidiaPackages.stable;
      modesetting.enable = true;
    };
  };
}
