# Blender - 3D creation suite

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
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/network.nix
      ../../../lib/features/audio.nix
      ../../../lib/features/xdg-desktop.nix
    ];

    config.app = {
      name = "blender";
      package = pkgs.blender;
      packageName = "blender";

      persistence.user = {
        # Config, addons, presets, scripts
        persist = [
          ".config/blender"
        ];

        # Cache (thumbnails, compiled shaders, etc.)
        cache = [
          ".cache/blender"
        ];
      };

      # Project file access
      nixpakModules = [
        (
          { sloth, ... }:
          {
            bubblewrap.bind.rw = [
              (sloth.concat' sloth.homeDir "/Documents/school")
            ];
          }
        )
      ];
    };
  }
)
