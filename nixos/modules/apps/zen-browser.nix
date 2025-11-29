# Zen Browser (Firefox-based privacy-focused browser)

(import ../../../lib/apps.nix).mkApp (
  { config, lib, pkgs, ... }: {
    imports = [
      ../../../lib/features/browser.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/xdg-desktop.nix
    ];

    config.app = {
      name = "zen-browser";
      package = pkgs.zen-browser;
      packageName = "zen";

      persistence.user.persist = [
        ".zen"
      ];

      # Sandbox both zen and zen-beta executables
      nixpakModules = [
        ({ lib, ... }: {
          app.extraEntrypoints = [ "/bin/zen-beta" ];
        })
      ];
    };
  }
)
