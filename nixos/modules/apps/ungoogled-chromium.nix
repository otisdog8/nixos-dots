# Ungoogled Chromium - ephemeral browser with tmpfs homedir

(import ../../../lib/apps.nix).mkApp (
  {
    config,
    lib,
    pkgs,
    ...
  }:
  {
    imports = [
      ../../../lib/features/chromium.nix
      ../../../lib/features/browser.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/xdg-desktop.nix
    ];

    config.app = {
      name = "ungoogled-chromium";
      package = pkgs.ungoogled-chromium;
      packageName = "chromium";
      desktopFileName = "chromium-browser.desktop";

      # Use a separate config dir to avoid conflicts with regular chromium
      chromium.basePath = ".config/ungoogled-chromium";

      # No persistence - profile lives on tmpfs and is wiped on reboot
      persistence.user.persist = lib.mkForce [ ];
      persistence.user.cache = lib.mkForce [ ];
    };
  }
)
