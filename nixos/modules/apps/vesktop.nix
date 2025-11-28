# Vesktop (third-party Discord client)

(import ../../../lib/apps.nix).mkApp (
  { config, lib, pkgs, ... }: {
    imports = [
      ../../../lib/features/chromium.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/network.nix
      ../../../lib/features/audio.nix
      ../../../lib/features/screen-capture.nix
      ../../../lib/features/camera.nix
      ../../../lib/features/xdg-desktop.nix
      ../../../lib/features/x11.nix
      ../../../lib/features/system-tray.nix
    ];

    config.app = {
      name = "vesktop";
      package = pkgs.vesktop;
      packageName = "vesktop";

      # Vesktop stores its data under sessionData subdirectory
      chromium.basePath = ".config/vesktop/sessionData";

      # Persist the parent .config/vesktop directory
      persistence.user.persist = [
        ".config/vesktop"
      ];

      # Add Crashpad which is outside sessionData
      persistence.user.cache = [
        ".config/vesktop/Crashpad"
      ];
    };
  }
)
