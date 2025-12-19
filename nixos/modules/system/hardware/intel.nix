# Intel integrated graphics configuration
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.system.hardware.intel;
in
{
  options.modules.system.hardware.intel = {
    enable = lib.mkEnableOption "Intel integrated graphics";

    enableVaapi = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable VA-API hardware video acceleration";
    };

    enableCompute = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Intel compute runtime (OpenCL)";
    };
  };

  config = lib.mkIf cfg.enable {
    services.xserver.videoDrivers = [ "modesetting" ];

    hardware.graphics = {
      enable = true;
      extraPackages =
        with pkgs;
        [
          libvdpau-va-gl
          intel-media-driver
          intel-vaapi-driver
          libva-vdpau-driver
          vpl-gpu-rt
        ]
        ++ lib.optionals cfg.enableCompute [
          intel-compute-runtime
        ];
      extraPackages32 = with pkgs.pkgsi686Linux; [
        intel-media-driver
      ];
    };
  };
}
