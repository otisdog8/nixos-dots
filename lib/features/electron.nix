# Electron application feature (Chromium-based)
{ config, lib, ... }:

{
  # Electron apps are GUI apps with specific cache patterns
  imports = [ ./gui.nix ];

  config.app = {
    # Electron apps have predictable Chromium cache structure
    persistence.user.volatileCache = lib.mkDefault [
      ".config/${config.app.name}/Cache"
      ".config/${config.app.name}/GPUCache"
      ".config/${config.app.name}/Code Cache"
      ".config/${config.app.name}/DawnCache"
    ];

    # Electron-specific sandbox settings
    sandbox.extraArgs = lib.mkDefault [
      "--enable-features=UseOzonePlatform"
      "--ozone-platform=wayland"
    ];
  };
}
