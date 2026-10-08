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

    variantCommands = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            capabilities = lib.mkOption {
              type = lib.types.attrs;
              default = { };
              description = "Capability overrides, merged over app.capabilities.";
            };
            nixpakModules = lib.mkOption {
              type = lib.types.listOf lib.types.deferredModule;
              default = [ ];
              description = "Extra nixpak modules for this command only.";
            };
          };
        }
      );
      default = { };
      description = ''
        Extra commands (name → variant) that launch a second copy of the app's
        sandbox with more privileges, e.g. `claude-gpu`. The regular command is
        unchanged, so the wider access is only there when explicitly chosen.
        nixpak backend only.
      '';
    };

    groupCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "claude-agents";
      description = ''
        For a member of a sandbox group (modules.sandbox.groups): the app's
        regular command runs in its own container sandbox, and this extra
        command runs it in the group's sandbox (where a member's command runs
        by default): the shared container, or with sandbox.mode = "vm" the
        group's VM. null: the regular command joins the group. nixpak backend
        only.
      '';
    };

    multiInstance = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        The app runs several sessions on one data dir by itself, so its
        container and VM may run at the same time (lib/impl-lock.nix doesn't
        lock them against each other).
      '';
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

    # Environment the app runs with, in its container (bwrap --setenv) and its
    # VM (the guest-side environment of its command, restricted VMs included).
    # Fixed by the app module, never taken from the user's session. Not applied
    # to the unsandboxed `none` backend.
    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        QT_QPA_PLATFORM = "xcb";
      };
      description = "Environment variables for the app, in its container and its VM.";
    };

    # Layer-2 backend: nixpak (in-session bwrap), systemd (root-prepared stash
    # service, optionally a dedicated uid) or none (unsandboxed; storage at ~).
    # Set here in the app-spec so dispatch never forces the outer config; there is
    # no per-host override (lib/apps.nix). Unsandboxed must be explicit.
    defaultBackend = lib.mkOption {
      type = lib.types.enum [
        "none"
        "nixpak"
        "systemd"
      ];
      default = "nixpak";
      description = "Layer-2 sandbox backend for this app.";
    };

    # The human user whose session/home the app belongs to (the head is used).
    defaultUsernames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "jrt" ];
      description = "The app's session user; only the first entry is used.";
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

    # ── Unified storage model (Layer 1) ──────────────────────────────────────
    # A single per-path declaration that (per backend) drives the on-disk stash
    # location + tier (= backup policy), its creation, and the in-sandbox bind.
    # See lib/storage.nix.
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
                hidden per the backend's stash owner (derived from the systemd
                backend + dedicatedUser at lowering in lib/apps.nix). home = normal
                ~/<path> via impermanence (host-visible), still bound into the sandbox.
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
      description = "Unified per-path storage entries (see lib/storage.nix).";
    };

    # ── Backend-agnostic capability vocabulary (Layer 1) ─────────────────────
    # Features set these; backends lower them differently. Features may still add
    # raw nixpakModules; both bwrap backends consume them.
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
      # Where a network-enabled app may connect. Enforced by the systemd backend
      # (on the app's unit) and the VM backend (on the VM's passt unit) with
      # systemd's cgroup IP filter; see lib/netpolicy.nix. Per-host override:
      # modules.apps.<name>.sandbox.network.
      networkPolicy = {
        mode = lib.mkOption {
          type = lib.types.enum [
            "default"
            "open"
            "internet"
            "allowlist"
          ];
          default = "default";
          description = ''
            - default: the backend's own default (containers: open; VMs: internet)
            - open: anything the host can reach, including the LAN, the tailnet
              and services on the host itself
            - internet: public addresses only: no loopback, link-local, private
              (RFC 1918/ULA), CGNAT/tailnet or multicast addresses
            - allowlist: only `allow` (plus DNS, see `allowDns`)
          '';
        };
        allow = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [
            "192.168.1.20"
            "100.64.0.0/10"
          ];
          description = "Addresses/prefixes always allowed (also exceptions to `internet`'s blocks).";
        };
        deny = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Addresses/prefixes always denied, on top of the mode.";
        };
        allowDns = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "In allowlist mode, still allow the resolver the app uses.";
        };
        allowNames = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [
            "api.anthropic.com"
            "*.github.com"
          ];
          description = ''Names whose resolved addresses become reachable (in the restricted modes): "example.com" exactly, "*.example.com" any name under it. Needs systemd-resolved; enforced by sbx-dnsallow (modules/system/sandbox-dnsallow.nix).'';
        };
      };
      wayland = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "App needs a Wayland socket.";
      };
      microphone = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "App may record audio (the microphone, or other apps' sound), each time after your approval. Without it, `audio` is playback only.";
      };
      camera = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "App uses the camera (containers: /dev/video*; VMs: the camera attached on approval).";
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
          description = "Read-write binds: absolute, ./ or ../ ($PWD), or home-relative (lib/paths.nix).";
        };
        ro = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Read-only binds: absolute, ./ or ../ ($PWD), or home-relative (lib/paths.nix).";
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
