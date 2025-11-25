# Obsidian note-taking application
#
# Usage in your system config:
#   modules.apps.obsidian.enable = true;
#
# This creates a module at modules.apps.obsidian with options like:
#   - enable: Whether to install obsidian
#   - package: Which package to use
#   - persistConfig, persistData, enableCache: Persistence toggles
#   - sandbox.enable: Whether to sandbox with nixpak
#   - sandbox.extraBinds: Additional directories to expose
#   - sandbox.nixpakModules: Override nixpak configuration

(import ../../../lib/apps.nix).mkApp (
  { config, lib, pkgs, ... }: {
    # Compose features using imports
    # electron.nix brings gui (Wayland, GPU, audio) + Electron cache patterns
    imports = [
      ../../../lib/features/electron.nix  # Brings gui.nix automatically
      ../../../lib/features/needs-gpu.nix # Full GPU acceleration
      ../../../lib/features/network.nix   # Network for sync
    ];

    # Configure the app
    config.app = {
      name = "obsidian";
      package = pkgs.obsidian;
      packageName = "obsidian";

      # The electron + gui features already set up:
      # - .config/obsidian (persist)
      # - .cache/obsidian (volatile cache)
      # - .config/obsidian/{Cache,GPUCache,Code Cache,DawnCache} (volatile cache)
      # - Wayland, audio, GPU, fonts, etc. (nixpak)

      # Example: Add plugins directory to persistence
      # persistence.user.persist = lib.mkAfter [ ".config/obsidian/plugins" ];

      # Example: Override cache location
      # persistence.user.volatileCache = lib.mkForce [ ".config/obsidian/custom-cache" ];

      # Custom options specific to obsidian
      customOptions = config: {
        vaultPath = lib.mkOption {
          type = lib.types.str;
          default = "$HOME/Documents/Obsidian";
          description = "Path to Obsidian vault directory";
          example = "$HOME/notes";
        };
      };

      # Custom NixOS configuration for obsidian
      customConfig = { config, lib, pkgs }: {
        # Automatically bind vault path when sandboxed
        modules.apps.obsidian.sandbox.extraBinds = lib.mkIf
          (config.modules.apps.obsidian.sandbox.enable)
          [ config.modules.apps.obsidian.vaultPath ];

        # Could also add systemd services, environment variables, etc.
      };

      # Example: Add app-specific nixpak configuration
      # This gets merged with feature modules by nixpak's module system
      nixpakModules = [
        # ({ config, lib, sloth, ... }: {
        #   # Override GPU provider
        #   gpu.provider = lib.mkForce "mesa";
        #
        #   # Add custom bind mounts
        #   bubblewrap.bind.rw = [
        #     (sloth.concat' sloth.homeDir "/extra-vault")
        #   ];
        #
        #   # Override electron flags
        #   launch.args = lib.mkForce [
        #     "--enable-features=UseOzonePlatform,WaylandWindowDecorations"
        #     "--ozone-platform=wayland"
        #   ];
        # })
      ];
    };
  }
)
