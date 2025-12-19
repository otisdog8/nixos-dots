# Slipstream - FTL: Faster Than Light mod manager

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
      ../../../lib/features/xdg-desktop.nix
    ];

    config.app = {
      name = "slipstream";
      package = pkgs.slipstream;
      packageName = "slipstream";

      # Mod manager data and FTL game files
      persistence.user.large = [
        ".local/share/slipstream"
      ];

      # Need access to Steam folder for FTL game files
      nixpakModules = [
        (
          { lib, sloth, ... }:
          {
            bubblewrap.bind.rw = [
              (sloth.concat' sloth.homeDir "/.local/share/Steam")
            ];
          }
        )
      ];
    };
  }
)
