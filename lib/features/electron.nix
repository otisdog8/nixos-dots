# Electron application feature (Chromium-based)
{ config, lib, ... }:

{
  # Electron apps are GUI apps with specific cache patterns
  imports = [ ./gui.nix ];

  config.app = {
    # Electron apps have predictable Chromium cache structure
    persistence.user.cache = [
      ".config/${config.app.name}/Cache"
      ".config/${config.app.name}/GPUCache"
      ".config/${config.app.name}/Code Cache"
      ".config/${config.app.name}/DawnCache"
    ];

    # Note: Some Electron apps may need Wayland flags for proper operation:
    #   --enable-features=UseOzonePlatform --ozone-platform=wayland
    # These can be added per-app in the app module's nixpakModules if needed.
  };
}
