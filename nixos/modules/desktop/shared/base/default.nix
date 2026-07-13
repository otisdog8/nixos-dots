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
    # Ark is now a sandboxed framework app (nixpak, contained archive parsing)
    # instead of a raw systemPackages entry — see config.modules.apps.ark below.
    ../../../apps/ark.nix
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

    # Ark: sandboxed via the app framework (nixpak) instead of a raw package —
    # contains untrusted-archive parsing. Puts `ark` on PATH via finalPackage.
    modules.apps.ark.enable = true;

    # Core desktop packages
    environment.systemPackages = with pkgs; [
      # File managers and core apps
      lxqt.pcmanfm-qt
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
