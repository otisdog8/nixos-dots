# Blender - 3D creation suite

(import ../../../lib/apps.nix).mkApp (
  {
    config,
    lib,
    pkgs,
    inputs,
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
      package = inputs.nix-warez.packages.${pkgs.stdenv.hostPlatform.system}.blender_5_0;
      packageName = "blender";

      # v2 unified storage (replaces persistence.user.* + impermanence).
      storage = [
        {
          path = ".config/blender";
          tier = "persist";
        } # config, addons, presets, scripts
        {
          path = ".cache/blender";
          tier = "cache";
        } # thumbnails, compiled shaders
      ];

      # Project file access (raw nixpak module — coexists with app.storage).
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

      # v2 nixpak backend: storage-driven binds + tmpfiles instead of the legacy
      # persistence.user.* + impermanence path.
      defaultBackend = "nixpak";
    };
  }
)
