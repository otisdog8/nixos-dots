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
        description = "User paths for cache (ephemeral, can be cleared)";
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
        description = "System paths for cache (ephemeral, can be cleared)";
      };

      baked = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "System paths for /baked";
      };
    };

    # Nixpak sandbox configuration
    # Features and apps add modules to this list, which are composed by nixpak's module system
    nixpakModules = lib.mkOption {
      type = lib.types.listOf lib.types.deferredModule;
      default = [];
      description = ''
        List of nixpak modules to compose for sandboxing.

        Each module has access to nixpak's full API:
        - app.*: Application package and binPath
        - bubblewrap.*: Bubblewrap sandbox settings (network, bind mounts, sockets, etc.)
        - dbus.*: DBus policies
        - gpu.*: GPU acceleration settings
        - fonts.*, locale.*, etc.: System integration
        - sloth.*: Path construction helpers (homeDir, xdgConfigHome, etc.)

        Modules are merged by nixpak's module system, so:
        - Lists concatenate (bind.rw = [a] ++ [b])
        - Attrs merge recursively
        - Use lib.mkDefault/mkForce for priority control
      '';
      example = lib.literalExpression ''
        [
          # Basic GUI app
          ({ config, lib, pkgs, sloth, ... }: {
            gpu.enable = lib.mkDefault true;
            fonts.enable = true;
            bubblewrap = {
              sockets.wayland = true;
              sockets.pulse = true;
              bind.ro = [
                (sloth.concat' sloth.xdgConfigHome "/gtk-3.0")
              ];
            };
          })

          # App-specific overrides
          ({ sloth, ... }: {
            bubblewrap.bind.rw = [
              (sloth.concat' sloth.homeDir "/Documents/vault")
            ];
          })
        ]
      '';
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
