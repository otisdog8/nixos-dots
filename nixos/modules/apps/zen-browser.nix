# Zen Browser (Firefox-based privacy-focused browser)

(import ../../../lib/apps.nix).mkApp (
  {
    config,
    lib,
    pkgs,
    ...
  }:
  {
    imports = [
      ../../../lib/features/browser.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/xdg-desktop.nix
      ../../../lib/features/onepassword.nix
    ];

    config.app = {
      name = "zen-browser";
      package = pkgs.zen-browser;
      packageName = "zen";
      desktopFileName = "zen-beta.desktop";

      persistence.user.persist = [
        ".zen"
      ];

      # Sandbox both zen and zen-beta executables
      nixpakModules = [
        (
          { lib, ... }:
          {
            app.extraEntrypoints = [ "/bin/zen-beta" ];
          }
        )
      ];
    };
  }
)
