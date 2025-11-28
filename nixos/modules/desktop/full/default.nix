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
    ../shared/fonts
    ../shared/xdg
    ../shared/theming
    ../shared/printing
  ];

  options.modules.desktop.full = {
    enable = lib.mkEnableOption "full desktop environment";
  };

  config = lib.mkIf cfg.enable {
    # Enable Hyprland by default
    modules.desktop.full.hyprland.enable = lib.mkDefault true;

    # Enable SDDM by default
    modules.desktop.full.sddm.enable = lib.mkDefault true;

    # Enable auth (1Password, kwallet) by default
    modules.desktop.full.auth.enable = lib.mkDefault true;

    # Enable plymouth by default
    modules.desktop.full.plymouth.enable = lib.mkDefault true;

    # Enable desktop shared modules
    modules.desktop.shared.base.enable = lib.mkDefault true;
    modules.desktop.shared.fonts.enable = lib.mkDefault true;
    modules.desktop.shared.xdg.enable = lib.mkDefault true;
    modules.desktop.shared.theming.enable = lib.mkDefault true;
    modules.desktop.shared.printing.enable = lib.mkDefault true;

    # Enable app bundles by default
    modules.bundles.browsers.enable = lib.mkDefault true;
    modules.bundles.communication.enable = lib.mkDefault true;
    modules.bundles.productivity.enable = lib.mkDefault true;
    modules.bundles.media.enable = lib.mkDefault true;
  };
}
