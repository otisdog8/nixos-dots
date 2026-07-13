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

      # V2 CONVERSION NOTE (r2modman-style, deliberately NOT applied — needs validation
      # on the constitution host where slipstream/FTL actually runs). When ready:
      #   defaultBackend = "nixpak";
      #   storage = [
      #     { path = ".local/share/slipstream"; tier = "large"; location = "home"; }
      #   ];
      #   # keep the ~/.local/share/Steam bind below.
      # location=home is mandatory for the same reason as r2modman: slipstream patches
      # FTL's files inside Steam's (host-visible, legacy) library, so its own data must
      # stay host-visible too. Zero data movement (location=home == the current
      # impermanence path). Left legacy until it can be launched + verified on
      # constitution.
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
