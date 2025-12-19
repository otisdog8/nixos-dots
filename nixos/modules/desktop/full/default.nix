# Full desktop environment - Hyprland, SDDM, authentication
{ config, lib, ... }:
let
  cfg = config.modules.desktop.full;
in
{
  imports = [
    # Desktop components
    ./hyprland
    ./sddm
    ./auth.nix
    ./plymouth.nix

    # App bundles
    ../../bundles/browsers.nix
    ../../bundles/communication.nix
    ../../bundles/productivity.nix
    ../../bundles/media.nix

    # Shared desktop modules
    ../shared/base
    ../shared/fonts.nix
    ../shared/xdg.nix
    ../shared/theming.nix
    ../shared/printing.nix
  ];

  options.modules.desktop.full = {
    enable = lib.mkEnableOption "full desktop environment";
  };

  config = lib.mkIf cfg.enable {
    modules = {
      # Enable desktop components by default
      desktop = {
        full = {
          hyprland.enable = lib.mkDefault true;
          sddm.enable = lib.mkDefault true;
          auth.enable = lib.mkDefault true;
          plymouth.enable = lib.mkDefault true;
        };
        
        # Enable desktop shared modules
        shared = {
          base.enable = lib.mkDefault true;
          fonts.enable = lib.mkDefault true;
          xdg.enable = lib.mkDefault true;
          theming.enable = lib.mkDefault true;
          printing.enable = lib.mkDefault true;
        };
      };

      # Enable app bundles by default
      bundles = {
        browsers.enable = lib.mkDefault true;
        communication.enable = lib.mkDefault true;
        productivity.enable = lib.mkDefault true;
        media.enable = lib.mkDefault true;
      };
    };
  };
}
