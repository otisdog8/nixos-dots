# ProtonVPN GUI - VPN client

(import ../../../lib/apps.nix).mkApp (
  { config, lib, pkgs, ... }: {
    imports = [
      ../../../lib/features/gui.nix
      ../../../lib/features/network.nix
      ../../../lib/features/xdg-desktop.nix
      ../../../lib/features/system-tray.nix
    ];

    config.app = {
      name = "protonvpn-gui";
      package = pkgs.protonvpn-gui;
      packageName = "protonvpn-app";

      # ProtonVPN config and credentials
      persistence.user.persist = [
        ".config/Proton"
      ];
    };
  }
)
