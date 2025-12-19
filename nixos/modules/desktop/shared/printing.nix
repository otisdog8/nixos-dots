# Printing configuration - CUPS, Avahi
{ config, lib, ... }:
let
  cfg = config.modules.desktop.shared.printing;
in
{
  options.modules.desktop.shared.printing = {
    enable = lib.mkEnableOption "printing support";
  };

  config = lib.mkIf cfg.enable {
    services = {
      # CUPS printing
      printing = {
        enable = true;
        browsed.enable = false;
      };

      # Avahi for network printer discovery
      avahi = {
        enable = true;
        nssmdns4 = true;
        openFirewall = true;
      };
    };
  };
}
