# Quartus Prime FPGA Development Tool
{
  config,
  lib,
  pkgs,
  ...
}:
let
  appName = "quartus-prime";
  cfg = config.modules.apps.${appName};
in
{
  options.modules.apps.${appName} = {
    enable = lib.mkEnableOption "Quartus Prime FPGA development tool";
  };

  config = lib.mkIf cfg.enable {
    # Install Quartus Prime
    environment.systemPackages = [ pkgs.quartus-prime-lite ];
  };
}
