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

    desktopFileName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Desktop file name for XDG associations (e.g., 'zen.desktop')";
    };

    # The app's org.freedesktop.Application D-Bus name, for forwarding URL/file args
    # to an ALREADY-RUNNING sandboxed instance (the systemd launcher can't re-pass
    # args to a live service). Registered on jrt's session bus via the bridge. May be
    # a PREFIX — the launcher enumerates the live bus name (gecko appends a per-profile
    # instance suffix, e.g. org.mozilla.zen.<hash>). "" → no forwarding (URL only
    # opens when the app is launched fresh).
    dbusName = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "org.freedesktop.Application D-Bus name (or prefix) for URL forwarding to a running instance.";
    };

    # The app's sandbox backend (Layer-2). Apps opt into v2 by setting this to
    # nixpak/systemd/vm (or "none" for unsandboxed v2); "legacy" keeps the pre-v2
    # path. This IS the effective backend — there is no per-host sandbox.backend
    # override (it would be inert; see lib/apps.nix). It lives in the app-spec
    # (independent eval) rather than being set via customConfig, so reading the
    # effective backend never forces the outer config mid-merge.
    defaultBackend = lib.mkOption {
      type = lib.types.enum [
        "legacy"
        "none"
        "nixpak"
        "systemd"
        "vm"
      ];
      default = "legacy";
      description = "Default Layer-2 sandbox backend for this app.";
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
        default = [ ];
        description = "User paths for /persist (mutable config/data)";
      };

      persistFiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "User file paths for /persist (mutable config/data files)";
      };

      large = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "User paths for /large (large persistent data)";
      };

      largeFiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "User file paths for /large (large persistent data files)";
      };

      cache = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "User paths for cache (ephemeral, can be cleared)";
      };

      cacheFiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "User file paths for cache (ephemeral, can be cleared)";
      };

      baked = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "User paths for /baked (immutable setup-time data)";
      };

      bakedFiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "User file paths for /baked (immutable setup-time data)";
      };
    };

    # System-level persistence (for system services, /var/lib, /etc, etc.)
    persistence.system = {
      persist = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "System paths for /persist";
      };

      large = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "System paths for /large";
      };

      cache = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "System paths for cache (ephemeral, can be cleared)";
      };

      baked = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "System paths for /baked";
      };
    };

    # ── v2: unified storage model (Layer 1) ──────────────────────────────────
    # A single per-path declaration that (per backend) drives the on-disk stash
    # location + tier (= backup policy), its creation, and the in-sandbox bind.
    # Coexists with the legacy persistence.user.* lists above; an app uses one or
    # the other depending on sandbox.backend. See lib/storage.nix.
    storage = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            path = lib.mkOption {
              type = lib.types.str;
              description = "Home-relative path inside the sandbox, e.g. \".config/obsidian\".";
            };
            tier = lib.mkOption {
              type = lib.types.enum [
                "persist"
                "large"
                "cache"
              ];
              default = "persist";
              description = ''
                Storage tier = backup policy: persist (backed up), large (persisted,
                not backed up), cache (disposable). baked is intentionally excluded
                — it has no backing subvol on most hosts.
              '';
            };
            location = lib.mkOption {
              type = lib.types.enum [
                "stash"
                "home"
              ];
              default = "stash";
              description = ''
                stash = /<tier>/sandbox/<app>/<path>, bound into the sandbox and
                hidden per sandbox.stashOwner. home = normal ~/<path> via
                impermanence (host-visible), still bound into the sandbox.
              '';
            };
            type = lib.mkOption {
              type = lib.types.enum [
                "dir"
                "file"
              ];
              default = "dir";
            };
            mode = lib.mkOption {
              type = lib.types.str;
              default = "0700";
            };
          };
        }
      );
      default = [ ];
      description = "v2 unified storage entries. Alternative to persistence.user.* for converted apps.";
    };

    # ── v2: backend-agnostic capability vocabulary (Layer 1) ──────────────────
    # Features set these; backends lower them differently. Introduced now; feature
    # conversion is incremental (unconverted features keep using nixpakModules,
    # still consumed by the bwrap backends).
    capabilities = {
      gpu = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "App needs the GPU.";
      };
      network = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "App needs network access.";
      };
      wayland = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "App needs a Wayland socket.";
      };
      x11 = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "App needs X11.";
      };
      audio = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "App needs audio (pulse + pipewire).";
      };
      fido = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          App needs FIDO/WebAuthn hardware security keys (raw /dev/hidraw*).
          Deliberately NOT implied by `gui` — only browsers / apps that use
          security keys should get raw HID access.
        '';
      };
      cwd = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Bind the current working directory ($PWD) read-write.";
      };
      # TODO(gitAncestor): a `capabilities.gitAncestor` that binds the project root
      # (nearest .git ancestor of $PWD) rw, for agents working across a repo rather
      # than just $PWD. Deferred because the semantics need a decision: nixpak's
      # bind.lastArg/firstArg bind the nearest EXISTING ancestor of a CLI arg, which
      # is not the same as "git root of $PWD" — the latter needs a launch-time
      # `git rev-parse --show-toplevel` (a runtime helper in the wrapper), not a
      # static bind. Pick the semantics before implementing.


      gitConfig = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Bind the user's git config (~/.gitconfig, ~/.config/git) read-only.";
      };
      binds = {
        rw = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Home-relative or absolute read-write binds.";
        };
        ro = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Home-relative or absolute read-only binds.";
        };
        dev = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Device binds.";
        };
      };
      dbus.policies = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.enum [
            "talk"
            "own"
          ]
        );
        default = { };
        description = "Session-bus policies (name → talk|own).";
      };
    };

    # Nixpak sandbox configuration
    # Features and apps add modules to this list, which are composed by nixpak's module system
    nixpakModules = lib.mkOption {
      type = lib.types.listOf lib.types.deferredModule;
      default = [ ];
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
      default = config: { };
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
      default =
        {
          config,
          lib,
          pkgs,
        }:
        { };
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
