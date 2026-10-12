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
      # Java Swing/AWT is X11-only (XWayland).
      ../../../lib/features/x11.nix
    ];

    config.app = {
      name = "slipstream";
      package = pkgs.slipstream;
      packageName = "slipstream";

      # Mirrors r2modman: a `location = "home"` storage entry, since slipstream
      # patches FTL's files inside Steam's host-visible library, so its own data must
      # stay host-visible too (location = "home" also leaves existing data in place).
      # TODO: runtime-test on constitution (where slipstream/FTL actually runs).
      defaultBackend = "nixpak";
      storage = [
        {
          path = ".local/share/slipstream";
          tier = "large";
          location = "home";
        }
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
