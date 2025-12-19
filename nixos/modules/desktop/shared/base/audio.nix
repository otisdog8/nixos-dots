# Audio configuration via PipeWire
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.desktop.shared.base.audio;
in
{
  options.modules.desktop.shared.base.audio = {
    enable = lib.mkEnableOption "audio support via PipeWire";
  };

  config = lib.mkIf cfg.enable {
    # PipeWire audio server
    services.pipewire = {
      enable = true;
      pulse.enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      jack.enable = true;
    };

    # Audio control GUI
    environment.systemPackages = with pkgs; [
      pavucontrol
    ];
  };
}
