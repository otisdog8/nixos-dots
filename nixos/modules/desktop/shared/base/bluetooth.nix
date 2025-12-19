# Bluetooth configuration
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.desktop.shared.base.bluetooth;
in
{
  options.modules.desktop.shared.base.bluetooth = {
    enable = lib.mkEnableOption "bluetooth support";
  };

  config = lib.mkIf cfg.enable {
    # Hardware bluetooth
    hardware.bluetooth.enable = true;

    # Blueman for GUI management
    services.blueman.enable = true;

    environment.systemPackages = with pkgs; [
      blueman
    ];

    # Persistence for bluetooth
    environment.persistence."/persist" = {
      directories = [
        "/var/lib/bluetooth"
      ];
    };
  };
}
