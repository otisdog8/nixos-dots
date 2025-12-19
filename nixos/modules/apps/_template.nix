# Template for creating new app modules
# Copy this file and customize for your app
#
# This template uses module-based architecture with nixpak integration.
# Apps compose features through imports and configure sandboxing via nixpak modules.

(import ../../../lib/apps.nix).mkApp (

  # This is an app spec module - evaluated with lib.evalModules
  {
    config,
    lib,
    pkgs,
    ...
  }:
  {

    # ═══════════════════════════════════════════════════════════════════════
    # STEP 1: Import feature modules
    # ═══════════════════════════════════════════════════════════════════════
    #
    # Feature modules set defaults for persistence AND nixpak sandboxing.
    # They compose through imports (e.g., electron.nix imports gui.nix)
    #
    # Available features:
    #   - gui.nix:         GUI apps (Wayland, audio, fonts, basic GPU, DBus)
    #   - electron.nix:    Electron apps (imports gui, adds cache + Wayland flags)
    #   - network.nix:     Network access
    #   - needs-gpu.nix:   Full GPU acceleration (NVIDIA, Vulkan, Mesa)
    #   - gaming.nix:      Gaming apps (imports gui + gpu + network + input devices)
    #   - browser.nix:     Web browsers (imports gui + network + downloads)
    #   - development.nix: Dev tools (imports gui + network + project directories)

    imports = [
      ../../../lib/features/electron.nix # Change to match your app
      ../../../lib/features/network.nix
    ];

    # ═══════════════════════════════════════════════════════════════════════
    # STEP 2: Configure the app
    # ═══════════════════════════════════════════════════════════════════════

    config.app = {
      # Required: App identity
      name = "APPNAME"; # Used for modules.apps.APPNAME
      package = pkgs.APPNAME; # Package to install
      packageName = "APPNAME"; # Binary name in package

      # Optional: Override default usernames for persistence
      # defaultUsernames = [ "alice" "bob" ];

      # ─────────────────────────────────────────────────────────────────────
      # Persistence
      # ─────────────────────────────────────────────────────────────────────
      #
      # Feature modules already set defaults (e.g., electron.nix sets cache paths).
      # List options merge ADDITIVELY - just add your paths and they'll combine!
      #
      # Available persistence types:
      #   - persist:        Mutable config/data (/persist)
      #   - large:          Large data files (/large)
      #   - cache:          Ephemeral cache, can be cleared (/cache)
      #   - baked:          Immutable setup data (/baked)

      # Add paths - they merge with feature defaults automatically
      # persistence.user.persist = [
      #   ".config/APPNAME/plugins"
      #   ".local/share/APPNAME"
      # ];

      # To REPLACE feature defaults instead of merging, use lib.mkForce
      # persistence.user.cache = lib.mkForce [
      #   ".cache/APPNAME"
      # ];

      # System-level persistence (rare for desktop apps)
      # persistence.system.persist = [ "/var/lib/APPNAME" ];

      # ─────────────────────────────────────────────────────────────────────
      # Nixpak Sandboxing
      # ─────────────────────────────────────────────────────────────────────
      #
      # Feature modules export nixpak configuration directly.
      # You can add app-specific nixpak modules here.
      #
      # Nixpak modules have access to:
      #   - app.*: Application package, binPath, extraEntrypoints
      #   - bubblewrap.*: Sandbox configuration (network, bind mounts, sockets, etc.)
      #   - dbus.*: DBus policies for desktop integration
      #   - gpu.*: GPU acceleration settings (enable, provider)
      #   - fonts.*, locale.*, etc.: System integration
      #   - launch.*: Command-line arguments to pass to the app
      #   - sloth.*: Path construction helpers
      #
      # Path construction with sloth:
      #   - sloth.homeDir: User's home directory
      #   - sloth.xdgConfigHome: $XDG_CONFIG_HOME (usually ~/.config)
      #   - sloth.xdgDataHome: $XDG_DATA_HOME (usually ~/.local/share)
      #   - sloth.xdgCacheHome: $XDG_CACHE_HOME (usually ~/.cache)
      #   - sloth.runtimeDir: $XDG_RUNTIME_DIR (usually /run/user/<uid>)
      #   - sloth.concat' base path: Concatenate paths (e.g., sloth.concat' sloth.homeDir "/vault")
      #   - sloth.env "VAR": Pass through environment variable

      nixpakModules = [
        # Example: Add custom bind mounts (lists merge additively)
        # ({ config, lib, sloth, ... }: {
        #   bubblewrap.bind.rw = [
        #     (sloth.concat' sloth.homeDir "/Documents/APPNAME")
        #     "/mnt/external-drive"
        #   ];  # These merge with feature defaults automatically
        # })

        # Example: Override GPU settings (scalars need mkForce)
        # ({ config, lib, ... }: {
        #   gpu.provider = lib.mkForce "mesa";  # or "bundle", "system"
        # })

        # Example: Add DBus policies (attrsets merge by default)
        # ({ config, lib, ... }: {
        #   dbus.policies = {
        #     "org.freedesktop.secrets" = "talk";
        #   };  # Merges with feature DBus policies
        # })

        # Example: Disable network (override boolean from network.nix)
        # ({ config, lib, ... }: {
        #   bubblewrap.network = lib.mkForce false;
        # })

        # Example: Add more bind mounts (lists merge!)
        # ({ config, lib, sloth, ... }: {
        #   bubblewrap.bind.ro = [
        #     (sloth.concat' sloth.xdgConfigHome "/mimeapps.list")
        #   ];  # Adds to bind.ro from features
        # })

        # Example: Share IPC namespace (for some X11 apps)
        # ({ config, lib, ... }: {
        #   bubblewrap.shareIpc = true;
        # })
      ];

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

      customConfig =
        {
          config,
          lib,
          pkgs,
        }:
        {
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
#     sandbox.enable = true;   # Enable nixpak sandboxing
#     sandbox.extraBinds = [   # Additional bind mounts (relative to $HOME or absolute)
#       "Documents/vault"      # Relative: expands to $HOME/Documents/vault
#       "/mnt/data"            # Absolute: used as-is
#     ];
#
#     # Per-host nixpak overrides
#     sandbox.nixpakModules = [
#       ({ config, lib, sloth, ... }: {
#         # This machine needs special GPU settings
#         gpu.provider = "bundle";
#
#         # Or add machine-specific bind mounts
#         bubblewrap.bind.ro = [
#           "/opt/company-certs"
#         ];
#       })
#     ];
#   };
#
# ═════════════════════════════════════════════════════════════════════════════

# ═════════════════════════════════════════════════════════════════════════════
# ADVANCED: NIXPAK MODULE REFERENCE
# ═════════════════════════════════════════════════════════════════════════════
#
# Common nixpak options you might need:
#
# ## Bubblewrap (sandbox)
#   bubblewrap.network = true/false;                    # Network access
#   bubblewrap.shareIpc = true/false;                   # Share IPC namespace
#   bubblewrap.bind.rw = [ paths ];                     # Read-write bind mounts
#   bubblewrap.bind.ro = [ paths ];                     # Read-only bind mounts
#   bubblewrap.bind.dev = [ "/dev/dri" ];              # Device bind mounts
#   bubblewrap.tmpfs = [ paths ];                       # Tmpfs locations
#   bubblewrap.sockets.wayland = true/false;            # Wayland socket
#   bubblewrap.sockets.x11 = true/false;                # X11 sockets
#   bubblewrap.sockets.pulse = true/false;              # PulseAudio socket
#   bubblewrap.sockets.pipewire = true/false;           # PipeWire socket
#   bubblewrap.apivfs.proc = true/false;                # Mount /proc
#   bubblewrap.apivfs.dev = true/false;                 # Mount /dev
#   bubblewrap.env.VAR_NAME = value;                    # Environment variables
#
# ## GPU
#   gpu.enable = true/false;                            # GPU acceleration
#   gpu.provider = "bundle"/"mesa"/"system";            # GPU provider
#
# ## DBus
#   dbus.enable = true/false;                           # DBus access
#   dbus.policies."org.service.Name" = "talk"/"own";    # DBus policies
#   dbus.mountDocumentPortal = true/false;              # Document portal
#
# ## System Integration
#   fonts.enable = true/false;                          # System fonts
#   locale.enable = true/false;                         # System locale
#   timezone.enable = true/false;                       # System timezone
#   etc.sslCertificates.enable = true/false;            # SSL certificates
#
# ## Application
#   app.package = pkgs.myapp;                           # The application package
#   app.binPath = "bin/myapp";                          # Binary path in package
#   app.extraEntrypoints = [ "/libexec/helper" ];       # Additional binaries
#   launch.args = [ "--flag" ];                         # Command-line arguments
#
# See nixpak documentation for the complete API:
# https://github.com/nixpak/nixpak
#
# ═════════════════════════════════════════════════════════════════════════════
