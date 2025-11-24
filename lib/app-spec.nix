# Base module for app specifications
# All app modules should be evaluated with this as a base
{ lib, ... }:

{
  options.app = {
    # Core identity
    name = lib.mkOption {
      type = lib.types.str;
      description = "App identifier (used for modules.apps.\${name})";
    };

    package = lib.mkOption {
      type = lib.types.package;
      description = "Package to install for this app";
    };

    packageName = lib.mkOption {
      type = lib.types.str;
      description = "Binary name within the package (for sandboxing)";
    };

    # Default usernames for user-level persistence
    defaultUsernames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "jrt" ];
      description = "Default users to apply persistence to";
    };

    # User-level persistence (applied to user directories like ~/.config, ~/.local/share)
    persistence.user = {
      persist = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "User paths for /persist (mutable config/data)";
      };

      large = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "User paths for /large (large persistent data)";
      };

      cache = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "User paths for /cache (persistent cache)";
      };

      volatileCache = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "User paths for /volatile-cache (cleared on boot)";
      };

      baked = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "User paths for /baked (immutable setup-time data)";
      };
    };

    # System-level persistence (for system services, /var/lib, /etc, etc.)
    persistence.system = {
      persist = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "System paths for /persist";
      };

      large = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "System paths for /large";
      };

      cache = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "System paths for /cache";
      };

      volatileCache = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "System paths for /volatile-cache";
      };

      baked = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "System paths for /baked";
      };
    };

    # Sandbox configuration
    sandbox = {
      gui = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether app needs GUI access";
      };

      network = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether app needs network access";
      };

      apivfs = {
        dev = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether to mount /dev in sandbox";
        };

        proc = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether to mount /proc in sandbox";
        };
      };

      dbus = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether to enable dbus in sandbox";
        };

        policies = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {};
          description = "DBus policies for desktop integration";
          example = {
            "org.freedesktop.Notifications" = "talk";
          };
        };
      };

      binds = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Device bind mounts (e.g., /dev/dri)";
      };

      sockets = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Sockets to expose (e.g., wayland, pulse)";
      };

      bind-rw = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Read-write path binds";
      };

      bind-ro = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Read-only path binds";
      };

      env = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Environment variables to pass through";
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Extra arguments to pass to sandboxed app";
      };
    };

    # Custom options that will be exposed in the final NixOS module
    # Apps set this to declare their own options
    customOptions = lib.mkOption {
      type = lib.types.raw;
      default = config: {};
      description = ''
        Function that takes the full system config and returns an attrset of option declarations.
        These will be merged into the final app module options.

        The config parameter allows options to reference system-wide settings in their defaults.
        Only access config in lazy positions (default values, descriptions).
      '';
      example = lib.literalExpression ''
        config: {
          vaultPath = lib.mkOption {
            type = lib.types.str;
            default = "''${config.users.users.''${config.mySystem.primaryUser}.home}/Documents/vault";
            description = "Path to vault directory";
          };
        }
      '';
    };

    # Additional NixOS configuration to merge into the final module
    customConfig = lib.mkOption {
      type = lib.types.raw;
      default = { config, lib, pkgs }: {};
      description = ''
        Function that takes {config, lib, pkgs} and returns additional NixOS configuration.
        This is merged into the final module's config section.
      '';
      example = lib.literalExpression ''
        { config, lib, pkgs }: {
          systemd.user.services.myapp = {
            description = "My App Service";
            wantedBy = [ "default.target" ];
            serviceConfig.ExecStart = "''${config.modules.apps.myapp.package}/bin/myapp";
          };
        }
      '';
    };
  };
}
