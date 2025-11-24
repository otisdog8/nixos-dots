# Template for creating new app modules
# Copy this file and customize for your app
#
# This template uses the NEW module-based architecture.
# Apps compose features through imports, declare custom options,
# and get full access to the module system's power.

(import ../../../lib/apps.nix).mkApp (

  # This is an app spec module - evaluated with lib.evalModules
  { config, lib, pkgs, ... }: {

    # ═══════════════════════════════════════════════════════════════════════
    # STEP 1: Import feature modules
    # ═══════════════════════════════════════════════════════════════════════
    #
    # Feature modules set defaults for persistence, sandboxing, etc.
    # They compose through imports (e.g., electron.nix imports gui.nix)
    #
    # Available features:
    #   - gui.nix:         GUI apps (Wayland, audio, fonts, basic GPU)
    #   - electron.nix:    Electron apps (imports gui, adds cache paths)
    #   - network.nix:     Network access
    #   - needs-gpu.nix:   Full GPU acceleration (NVIDIA, Vulkan, etc.)
    #   - gaming.nix:      Gaming apps (imports gui + gpu + network)
    #   - browser.nix:     Web browsers (imports gui + network)
    #   - development.nix: Dev tools (imports gui + network)

    imports = [
      ../../../lib/features/electron.nix  # Change to match your app
      ../../../lib/features/network.nix
    ];


    # ═══════════════════════════════════════════════════════════════════════
    # STEP 2: Configure the app
    # ═══════════════════════════════════════════════════════════════════════

    config.app = {
      # Required: App identity
      name = "APPNAME";                    # Used for modules.apps.APPNAME
      package = pkgs.APPNAME;              # Package to install
      packageName = "APPNAME";             # Binary name in package

      # Optional: Override default usernames for persistence
      # defaultUsernames = [ "alice" "bob" ];

      # ─────────────────────────────────────────────────────────────────────
      # Persistence
      # ─────────────────────────────────────────────────────────────────────
      #
      # Feature modules already set defaults (e.g., electron.nix sets cache paths)
      # You can add more or override using lib.mkBefore/mkAfter/mkForce
      #
      # Available persistence types:
      #   - persist:        Mutable config/data (/persist)
      #   - large:          Large data files (/large)
      #   - cache:          Persistent cache (/cache)
      #   - volatileCache:  Cleared on boot (/volatile-cache)
      #   - baked:          Immutable setup data (/baked)

      # Add additional persistence paths
      # persistence.user.persist = lib.mkAfter [
      #   ".config/APPNAME/plugins"
      #   ".local/share/APPNAME"
      # ];

      # Override defaults from features
      # persistence.user.volatileCache = lib.mkForce [
      #   ".cache/APPNAME"
      # ];

      # System-level persistence (rare for desktop apps)
      # persistence.system.persist = [ "/var/lib/APPNAME" ];

      # ─────────────────────────────────────────────────────────────────────
      # Sandboxing
      # ─────────────────────────────────────────────────────────────────────
      #
      # Feature modules set sandbox defaults.
      # You can override specific settings if needed.

      # Override network access
      # sandbox.network = lib.mkForce false;

      # Add custom bind mounts
      # sandbox.bind-rw = lib.mkAfter [ "/extra/path" ];

      # Override GUI setting
      # sandbox.gui = lib.mkForce false;

      # ─────────────────────────────────────────────────────────────────────
      # Custom Options
      # ─────────────────────────────────────────────────────────────────────
      #
      # Declare app-specific options that users can configure.
      # These get exposed as modules.apps.APPNAME.<optionname>
      #
      # The config parameter gives access to the full system config,
      # allowing defaults to reference system-wide settings!

      customOptions = config: {
        # Example: Simple option
        # enableFeatureX = lib.mkEnableOption "Feature X for APPNAME";

        # Example: Option with system-wide default
        # dataDir = lib.mkOption {
        #   type = lib.types.str;
        #   # Can reference system config in defaults!
        #   default = "${config.users.users.${config.mySystem.primaryUser or "jrt"}.home}/.local/share/APPNAME";
        #   description = "Data directory for APPNAME";
        # };

        # Example: Enum option
        # logLevel = lib.mkOption {
        #   type = lib.types.enum [ "debug" "info" "warn" "error" ];
        #   default = "info";
        #   description = "Log level for APPNAME";
        # };
      };

      # ─────────────────────────────────────────────────────────────────────
      # Custom Config
      # ─────────────────────────────────────────────────────────────────────
      #
      # Additional NixOS configuration for this app.
      # Can reference app's options via config.modules.apps.APPNAME
      #
      # Use this for:
      #   - Systemd services
      #   - Environment variables
      #   - Additional packages
      #   - Conditional logic based on custom options

      customConfig = { config, lib, pkgs }: {
        # Example: Bind custom dataDir into sandbox
        # modules.apps.APPNAME.sandbox.extraBinds = lib.mkIf
        #   (config.modules.apps.APPNAME.sandbox.enable)
        #   [ config.modules.apps.APPNAME.dataDir ];

        # Example: Systemd user service
        # systemd.user.services.APPNAME = lib.mkIf
        #   (config.modules.apps.APPNAME.enableFeatureX)
        #   {
        #     description = "APPNAME background service";
        #     wantedBy = [ "default.target" ];
        #     serviceConfig = {
        #       ExecStart = "${config.modules.apps.APPNAME.package}/bin/APPNAME-daemon";
        #       Restart = "on-failure";
        #     };
        #   };

        # Example: Environment variables
        # environment.sessionVariables = {
        #   APPNAME_LOG_LEVEL = config.modules.apps.APPNAME.logLevel;
        # };

        # Example: Install additional packages
        # environment.systemPackages = lib.optionals
        #   (config.modules.apps.APPNAME.enableFeatureX)
        #   [ pkgs.APPNAME-plugin ];
      };
    };
  }
)


# ═════════════════════════════════════════════════════════════════════════════
# USAGE IN SYSTEM CONFIG
# ═════════════════════════════════════════════════════════════════════════════
#
# After creating your app module, import it in your system:
#
#   imports = [
#     ./nixos/modules/apps/APPNAME.nix
#   ];
#
# Then configure it:
#
#   modules.apps.APPNAME = {
#     enable = true;
#     package = pkgs.APPNAME;  # Optional: override package
#
#     # Custom options you declared
#     # dataDir = "/custom/path";
#     # logLevel = "debug";
#
#     # Persistence toggles
#     persistConfig = true;   # Persist config files
#     persistData = true;     # Persist data files
#     enableCache = true;     # Enable caching
#
#     # Sandboxing
#     sandbox.enable = false;  # Enable nixpak sandboxing
#     sandbox.extraBinds = [   # Additional bind mounts
#       "Documents"
#       "/mnt/data"
#     ];
#   };
#
# ═════════════════════════════════════════════════════════════════════════════


# ═════════════════════════════════════════════════════════════════════════════
# ADVANCED: FEATURE COMPOSITION EXAMPLES
# ═════════════════════════════════════════════════════════════════════════════
#
# Features compose through imports. Here are some common patterns:
#
# Simple GUI app:
#   imports = [ ../../../lib/features/gui.nix ];
#
# Electron app with network:
#   imports = [
#     ../../../lib/features/electron.nix  # Imports gui automatically
#     ../../../lib/features/network.nix
#   ];
#
# Game:
#   imports = [ ../../../lib/features/gaming.nix ];  # Imports gui + gpu + network
#
# Browser:
#   imports = [ ../../../lib/features/browser.nix ];  # Imports gui + network
#
# CLI tool with no GUI:
#   imports = [ ../../../lib/app-spec.nix ];  # Base only, no features
#
# Custom feature combination:
#   imports = [
#     ../../../lib/features/gui.nix
#     ../../../lib/features/needs-gpu.nix
#     ../../../lib/features/network.nix
#   ];
