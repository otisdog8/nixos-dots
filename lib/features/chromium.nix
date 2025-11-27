# Chromium-based application feature (Chrome, Brave, Electron apps, etc.)
{ config, lib, ... }:

{
  # Chromium-based apps are GUI apps with specific cache patterns
  imports = [
    ./gui.nix
    ../app-spec.nix
  ];

  options.app.chromium = {
    basePath = lib.mkOption {
      type = lib.types.str;
      default = ".config/${config.app.name}";
      description = "Base path for chromium app data (for apps with non-standard layouts)";
    };
  };

  config.app = {
    # Standard chromium config location
    persistence.user.persist = [
      config.app.chromium.basePath
    ];

    # Chromium apps have predictable cache structure
    persistence.user.cache = [
      "${config.app.chromium.basePath}/Cache"
      "${config.app.chromium.basePath}/GPUCache"
      "${config.app.chromium.basePath}/Code Cache"
      "${config.app.chromium.basePath}/DawnCache"
    ];

    # Note: Some Chromium apps may need Wayland flags for proper operation:
    #   --enable-features=UseOzonePlatform --ozone-platform=wayland
    # These can be added per-app in the app module's nixpakModules if needed.
  };
}
