# OpenRazer configuration for Razer peripherals
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.system.hardware.openrazer;
in
{
  options.modules.system.hardware.openrazer = {
    enable = lib.mkEnableOption "OpenRazer for Razer peripherals";
  };

  config = lib.mkIf cfg.enable {
    # Enable OpenRazer hardware support
    hardware.openrazer.enable = true;

    # Add OpenRazer daemon and Polychromatic frontend
    environment.systemPackages = with pkgs; [
      openrazer-daemon
      polychromatic
    ];
  };
}
