# Chromium web browser

(import ../../../lib/apps.nix).mkApp (
  { config, lib, pkgs, ... }: {
    imports = [
      ../../../lib/features/chromium.nix
      ../../../lib/features/browser.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/xdg-desktop.nix
    ];

    config.app = {
      name = "chromium";
      package = pkgs.chromium;
      packageName = "chromium";

      # Chromium uses standard .config/chromium location
      # chromium.basePath defaults to ".config/${name}" which is correct
    };
  }
)
