{ inputs, lib, pkgs, ... }:
{
    boot.plymouth = {
      enable = true;
      theme = "hexa_retro";
      themePackages = with pkgs; [
        # By default we would install all themes
        (adi1090x-plymouth-themes.override {
          selected_themes = [ "hexa_retro" ];
        })
      ];
      extraConfig = ''
DeviceScale=1
      '';
    };

}
