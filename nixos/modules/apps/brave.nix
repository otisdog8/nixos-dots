# Brave web browser

(import ../../../lib/apps.nix).mkApp (
  { config, lib, pkgs, ... }: {
    imports = [
      ../../../lib/features/chromium.nix
      ../../../lib/features/browser.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/xdg-desktop.nix
    ];

    config.app = {
      name = "brave";
      package = pkgs.brave;
      packageName = "brave";

      # Brave uses .config/BraveSoftware/Brave-Browser
      chromium.basePath = ".config/BraveSoftware/Brave-Browser";

      # Additional cache paths
      persistence.user.cache = [
        ".config/BraveSoftware/Brave-Browser/Default/Service Worker/CacheStorage"
      ];
    };
  }
)
