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

      # Left on the legacy path pending validation on the constitution host (where
      # slipstream/FTL actually runs). To convert: mirror r2modman — nixpak backend with
      # a `location = "home"` storage entry for .local/share/slipstream, since it patches
      # FTL's files inside Steam's host-visible library, so its own data must stay
      # host-visible too (and location=home means zero data movement).
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
