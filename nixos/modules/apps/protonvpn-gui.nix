# ProtonVPN GUI - VPN client

(import ../../../lib/apps.nix).mkApp (
  {
    config,
    lib,
    pkgs,
    ...
  }:
  {
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

      # Unsandboxed: it drives NetworkManager over the system bus.
      defaultBackend = "none";

      # ProtonVPN config and credentials
      storage = [
        {
          path = ".config/Proton";
          tier = "persist";
        }
      ];
    };
  }
)
