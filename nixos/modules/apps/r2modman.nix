# r2modman - Game mod manager (Risk of Rain 2, Lethal Company, etc.)

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
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/network.nix
      ../../../lib/features/xdg-desktop.nix
    ];

    config.app = {
      name = "r2modman";
      package = pkgs.r2modman;
      packageName = "r2modman";

      # r2modman config and mod data
      persistence.user.persist = [
        ".config/r2modmanPlus-local"
      ];

      # Access to Steam paths for game files
      nixpakModules = [
        (
          { lib, sloth, ... }:
          {
            bubblewrap.bind.rw = [
              (sloth.concat' sloth.homeDir "/.steam")
              (sloth.concat' sloth.homeDir "/.local/share/Steam")
            ];
          }
        )
      ];
    };
  }
)
