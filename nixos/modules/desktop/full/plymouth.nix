# Plymouth boot splash screen
{ config, lib, pkgs, ... }:
let
  cfg = config.modules.desktop.full.plymouth;
in
{
  options.modules.desktop.full.plymouth = {
    enable = lib.mkEnableOption "Plymouth boot splash";

    theme = lib.mkOption {
      type = lib.types.str;
      default = "hexa_retro";
      description = "Plymouth theme to use";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.plymouth = {
      enable = true;
      theme = cfg.theme;
      themePackages = with pkgs; [
        (adi1090x-plymouth-themes.override {
          selected_themes = [ cfg.theme ];
        })
      ];
      extraConfig = ''
        DeviceScale=1
      '';
    };
  };
}
