# Base desktop configuration - audio, bluetooth, graphics, core utilities
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  cfg = config.modules.desktop.shared.base;
in
{
  imports = [
    ./audio.nix
    ./bluetooth.nix
    ./graphics-tools.nix
  ];

  options.modules.desktop.shared.base = {
    enable = lib.mkEnableOption "base desktop configuration";
  };

  config = lib.mkIf cfg.enable {
    # Enable audio and bluetooth via submodules
    modules.desktop.shared.base.audio.enable = lib.mkDefault true;
    modules.desktop.shared.base.bluetooth.enable = lib.mkDefault true;

    # Hardware graphics
    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };

    # Services
    services = {
      # Libinput for input devices
      libinput.enable = true;

      # Logind settings
      logind.settings.Login = {
        HandlePowerKey = "ignore";
        HandleLidSwitch = "ignore";
      };

      # Player control daemon
      playerctld.enable = true;
    };

    # Core desktop packages
    environment.systemPackages = with pkgs; [
      # File managers and core apps
      lxqt.pcmanfm-qt
      kdePackages.ark
    ];

    # Home-manager services
    home-manager.users.${username} = {
      # Trayscale - Tailscale system tray
      services.trayscale.enable = true;

      # Dconf settings for virt-manager
      dconf.settings = {
        "org/virt-manager/virt-manager/connections" = {
          autoconnect = [ "qemu:///system" ];
          uris = [ "qemu:///system" ];
        };
      };
    };
  };
}
