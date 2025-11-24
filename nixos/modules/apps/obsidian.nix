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

# Import the app spec as a separate module file to preserve relative imports
let
  appSpec = { config, lib, pkgs, ... }: {
    # Compose features using imports
    # Use path literals to make them relative to THIS file
    imports = [
      (../../../lib/features/electron.nix)
      (../../../lib/features/needs-gpu.nix)
      (../../../lib/features/network.nix)
    ];

    # Configure the app
    config.app = {
      name = "obsidian";
      package = pkgs.obsidian;
      packageName = "obsidian";

      # The electron feature already sets up .config/obsidian and cache paths
      # We can add additional persistence if needed:
      # persistence.user.persist = lib.mkAfter [ ".config/obsidian/plugins" ];

      # Or override defaults from features:
      # persistence.user.volatileCache = lib.mkForce [ ".config/obsidian/Cache" ];

      # Custom options specific to obsidian
      # These get exposed as modules.apps.obsidian.<optionname>
      customOptions = config: {
        # Example: Let users configure vault path
        # They can reference system-wide settings in defaults!
        vaultPath = lib.mkOption {
          type = lib.types.str;
          default = "$HOME/Documents/Obsidian";
          description = "Path to Obsidian vault directory";
          example = "$HOME/notes";
        };
      };

      # Custom NixOS configuration for obsidian
      # Can reference the app's own options via config.modules.apps.obsidian
      customConfig = { config, lib, pkgs }: {
        # Example: Bind the vault path into sandbox automatically
        modules.apps.obsidian.sandbox.extraBinds = lib.mkIf
          (config.modules.apps.obsidian.sandbox.enable)
          [ config.modules.apps.obsidian.vaultPath ];

        # Could also add systemd services, environment variables, etc.
      };
    };
  };
in

(import ../../../lib/apps.nix).mkApp appSpec
