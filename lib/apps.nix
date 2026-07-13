{
  # Module-based app builder
  # Takes an app spec module and generates a configurable NixOS module
  #
  # Usage:
  #   (import ../lib/apps.nix).mkApp ./my-app.nix
  #
  # Where my-app.nix is a module like:
  #   { config, lib, pkgs, ... }: {
  #     imports = [ ../lib/features/electron.nix ../lib/features/network.nix ];
  #     config.app = {
  #       name = "myapp";
  #       package = pkgs.myapp;
  #       # ... custom options, overrides, etc.
  #     };
  #   }

  mkApp =
    appSpecModule:
    {
      config,
      lib,
      pkgs,
      inputs ? { },
      ...
    }:
    let
      # Evaluate the app spec module to get config.app.*
      appSpec = lib.evalModules {
        modules = [ appSpecModule ];
        specialArgs = {
          inherit pkgs;
          inherit inputs;
        };
      };

      # Extract the evaluated app configuration
      appCfg = appSpec.config.app;
      appName = appCfg.name;

      # The user-facing config for this app
      cfg = config.modules.apps.${appName};

      # Evaluate custom options with full config access
      customOpts = appCfg.customOptions config;

    in
    {
      # Generate options from the app spec
      options.modules.apps.${appName} = {
        enable = lib.mkEnableOption appName;

        package = lib.mkOption {
          type = lib.types.package;
          default = appCfg.package;
          description = "Package to use for ${appName}";
        };

        persistConfig = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to persist ${appName} config files";
        };

        persistData = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to persist ${appName} data files";
        };

        enableCache = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to enable cache for ${appName}";
        };

        sandbox = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether to sandbox ${appName} using nixpak (legacy path)";
          };

          backend = lib.mkOption {
            type = lib.types.enum [
              "legacy"
              "none"
              "nixpak"
              "systemd"
              "vm"
            ];
            default = appCfg.defaultBackend;
            description = ''
              Sandbox backend (Layer-2 lowering). "legacy" = the untouched pre-v2
              path driven by persistence.user.* + sandbox.enable. "none" = v2 but
              unsandboxed (storage at its home location). nixpak/systemd/vm =
              sandboxed. Defaults to app.defaultBackend; converted apps set that
              and declare app.storage.
            '';
          };

          dedicatedUser = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "systemd backend only, CLI apps only: run under a dedicated app-<name> uid.";
          };

          stashOwner = lib.mkOption {
            type = lib.types.enum [
              "user"
              "root"
              "dedicated"
            ];
            default = "user";
            description = ''
              Per-app stash ownership. "user" = jrt-owned (rootless nixpak). The
              systemd backend derives root/dedicated from backend+dedicatedUser at
              lowering time (Phase 2); see lib/storage.nix.
            '';
          };

          envMode = lib.mkOption {
            type = lib.types.enum [
              "inject"
              "defaults"
            ];
            default = "inject";
            description = "systemd/vm env strategy: inject live session env, or derive sensible defaults.";
          };

          extraBinds = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Additional bind mounts for sandboxed ${appName} (relative to home or absolute paths)";
          };

          # See nixos/modules/apps/xwayland-forward.md.
          x11Forward = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              systemd + dedicatedUser only: let a dedicated-uid app reach jrt's XWayland
              (for apps needing XCB/X11 that can't do native Wayland). The launcher (as
              jrt) grants the app uid X access via `xhost +SI:localuser:app-<name>` and
              the inner sandbox binds the X socket + DISPLAY. SECURITY: this shares jrt's
              X server, which has NO inter-client isolation — the app can snoop/inject
              other X clients. Enable only where XWayland is required; the isolated path
              is a per-app xwayland-satellite (see the doc).
            '';
          };

          sharedDownloads = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              systemd + dedicatedUser only: bind jrt's ~/Downloads/${appName} in AS the
              app's ~/Downloads, so saved files land in a host-visible per-app subdir of
              jrt's real Downloads (on /large, persisted) instead of the app's hidden
              home. The launcher ACL-grants the app uid on that subdir.
            '';
          };

          nixpakModules = lib.mkOption {
            type = lib.types.listOf lib.types.deferredModule;
            default = [ ];
            description = ''
              Additional nixpak modules to merge with feature modules.
              Allows per-host nixpak configuration overrides.
            '';
          };
        };

        finalPackage = lib.mkOption {
          type = lib.types.package;
          readOnly = true;
          description = ''
            The final package to use (sandboxed if sandbox.enable is true, otherwise the base package).
            This is what gets installed in environment.systemPackages and should be used in customConfig.
          '';
        };

        isDefaultBrowser = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether to set this app as the default browser (requires desktopFileName to be set)";
        };
      }
      # Merge in custom options declared by the app
      // customOpts;

      # Generate config from the app spec
      config =
        let
          # Create sandboxed package if enabled
          sandboxedPackage =
            if cfg.sandbox.enable then
              let
                nixpakLib =
                  inputs.nixpak or (builtins.throw "nixpak not available - add nixpak to flake inputs");
                mkNixPak = nixpakLib.lib.nixpak {
                  inherit lib pkgs;
                };
              in
              (mkNixPak {
                config =
                  {
                    config,
                    lib,
                    pkgs,
                    sloth,
                    ...
                  }:
                  {
                    # Compose all nixpak modules from features and user
                    imports =
                      # Modules from features (gui.nix, electron.nix, etc.)
                      appCfg.nixpakModules
                      # Capability lowering: features increasingly declare
                      # app.capabilities.* instead of raw nixpakModules; the legacy
                      # path must lower them too or legacy apps silently lose
                      # network/gpu/audio/fido. Behavior-preserving (empty caps →
                      # no-op), so pre-capability legacy apps are unaffected.
                      ++ [ (import ./capabilities-nixpak.nix { inherit lib; } appCfg.capabilities) ]
                      # Per-host override modules
                      ++ cfg.sandbox.nixpakModules;

                    # Base configuration - set package and binPath
                    app.package = cfg.package;
                    app.binPath = "bin/${appCfg.packageName}";

                    # Network disabled by default (slightly higher priority than mkDefault)
                    bubblewrap.network = lib.mkOverride 999 false;

                    # Bind persistence paths automatically
                    # These are the paths that impermanence will mount to $HOME
                    bubblewrap.bind.rw =
                      # User's home directories from ALL persistence types
                      (lib.optionals cfg.persistConfig (
                        map (p: sloth.concat' sloth.homeDir "/${p}") appCfg.persistence.user.persist
                      ))
                      ++ (lib.optionals cfg.persistData (
                        map (p: sloth.concat' sloth.homeDir "/${p}") appCfg.persistence.user.large
                      ))
                      ++ (lib.optionals cfg.enableCache (
                        map (p: sloth.concat' sloth.homeDir "/${p}") appCfg.persistence.user.cache
                      ))
                      # User's extra binds (convert relative paths to absolute)
                      ++ (map (
                        p:
                        if lib.hasPrefix "/" p then
                          p # Absolute path
                        else if lib.hasPrefix "." p then
                          sloth.concat' (sloth.env "PWD") "/${p}"
                        else
                          sloth.concat' sloth.homeDir "/${p}" # Relative path
                      ) cfg.sandbox.extraBinds);
                  };
              }).config.env
            else
              cfg.package;

          # Evaluate custom config with full nixos config
          customCfg = appCfg.customConfig { inherit config lib pkgs; };

          # ── v2 backend dispatch (Layer 2) ─────────────────────────────────
          # The effective backend comes from the app-spec (independent eval), NOT
          # from reading cfg.sandbox.backend. Reading a cfg.sandbox.* option in a
          # mkIf *condition* below would force the outer module merge to resolve
          # that option while it is still collecting the very definitions the mkIf
          # guards → infinite recursion. app.defaultBackend has no such dependency.
          # Legacy apps (defaultBackend = "legacy") are entirely untouched.
          effectiveBackend = appCfg.defaultBackend;
          isLegacy = effectiveBackend == "legacy";
          storage = import ./storage.nix { inherit lib; } {
            inherit appName appCfg;
            username = builtins.head appCfg.defaultUsernames;
            # nixpak/none → jrt-owned (traversable). systemd same-uid → root lock;
            # systemd + dedicatedUser → per-uid lock.
            stashOwner =
              if effectiveBackend == "systemd" then
                (if cfg.sandbox.dedicatedUser then "dedicated" else "root")
              else
                "user";
            forceHome =
              (config.modules.sandbox.forceHomeLocation or false) || effectiveBackend == "none";
          };
          # Guard the registry lookup: the module system forces mkIf *content*
          # while computing unmatchedDefns even when the condition is false, so a
          # legacy app must NOT index the registry (it has no "legacy" key).
          backendResult =
            if isLegacy then
              {
                package = sandboxedPackage;
                systemConfig = { };
              }
            else
              (import ./backends/default.nix).${effectiveBackend} {
                inherit
                  appName
                  appCfg
                  cfg
                  config
                  lib
                  pkgs
                  inputs
                  storage
                  ;
              };
          finalPkg = backendResult.package;
        in
        lib.mkMerge (
          [
            # Expose the final package
            {
              modules.apps.${appName}.finalPackage = finalPkg;
            }

            # Base config - always applied when enabled
            (lib.mkIf cfg.enable {
              environment.systemPackages = [ finalPkg ];
            })

            # v2: backend-emitted system config (tmpfiles, persistence, units).
            # Inactive for legacy apps (their storage/backend paths stay unused).
            (lib.mkIf (cfg.enable && !isLegacy) backendResult.systemConfig)

            # System-level persistence
            (lib.mkIf (cfg.enable && appCfg.persistence.system.persist != [ ]) {
              environment.persistence."/persist".directories = appCfg.persistence.system.persist;
            })

            (lib.mkIf (cfg.enable && appCfg.persistence.system.large != [ ]) {
              environment.persistence."/large".directories = appCfg.persistence.system.large;
            })

            (lib.mkIf (cfg.enable && appCfg.persistence.system.cache != [ ]) {
              environment.persistence."/cache".directories = appCfg.persistence.system.cache;
            })

            (lib.mkIf (cfg.enable && appCfg.persistence.system.baked != [ ]) {
              environment.persistence."/baked".directories = appCfg.persistence.system.baked;
            })

            # Custom config from app spec
            (lib.mkIf cfg.enable customCfg)

            # Default browser XDG configuration
            (lib.mkIf (cfg.enable && cfg.isDefaultBrowser && appCfg.desktopFileName != null) {
              home-manager.users.jrt.xdg.mimeApps = {
                enable = true;
                defaultApplications = {
                  "default-web-browser" = [ appCfg.desktopFileName ];
                  "text/html" = [ appCfg.desktopFileName ];
                  "x-scheme-handler/http" = [ appCfg.desktopFileName ];
                  "x-scheme-handler/https" = [ appCfg.desktopFileName ];
                  "x-scheme-handler/about" = [ appCfg.desktopFileName ];
                  "x-scheme-handler/unknown" = [ appCfg.desktopFileName ];
                };
              };
            })
          ]
          ++
            # User-level persistence — LEGACY apps only. A v2 app gets its home
            # binds from the backend (storage.homePersistence); if a feature it
            # imports still sets persistence.user.* (e.g. chromium.nix on tetrio),
            # emitting these too would double-mount against the stash binds — the
            # very cross-authority desync this redesign removes.
            (lib.optionals isLegacy (lib.flatten (
              map (username: [
                # User persistence - /persist directories
                (lib.mkIf (cfg.enable && cfg.persistConfig && appCfg.persistence.user.persist != [ ]) {
                  environment.persistence."/persist".users.${username}.directories = appCfg.persistence.user.persist;
                })

                # User persistence - /persist files
                (lib.mkIf (cfg.enable && cfg.persistConfig && appCfg.persistence.user.persistFiles != [ ]) {
                  environment.persistence."/persist".users.${username}.files = appCfg.persistence.user.persistFiles;
                })

                # User persistence - /large directories
                (lib.mkIf (cfg.enable && cfg.persistData && appCfg.persistence.user.large != [ ]) {
                  environment.persistence."/large".users.${username}.directories = appCfg.persistence.user.large;
                })

                # User persistence - /large files
                (lib.mkIf (cfg.enable && cfg.persistData && appCfg.persistence.user.largeFiles != [ ]) {
                  environment.persistence."/large".users.${username}.files = appCfg.persistence.user.largeFiles;
                })

                # User persistence - /cache directories
                (lib.mkIf (cfg.enable && cfg.enableCache && appCfg.persistence.user.cache != [ ]) {
                  environment.persistence."/cache".users.${username}.directories = appCfg.persistence.user.cache;
                })

                # User persistence - /cache files
                (lib.mkIf (cfg.enable && cfg.enableCache && appCfg.persistence.user.cacheFiles != [ ]) {
                  environment.persistence."/cache".users.${username}.files = appCfg.persistence.user.cacheFiles;
                })

                # User persistence - /baked directories
                (lib.mkIf (cfg.enable && appCfg.persistence.user.baked != [ ]) {
                  environment.persistence."/baked".users.${username}.directories = appCfg.persistence.user.baked;
                })

                # User persistence - /baked files
                (lib.mkIf (cfg.enable && appCfg.persistence.user.bakedFiles != [ ]) {
                  environment.persistence."/baked".users.${username}.files = appCfg.persistence.user.bakedFiles;
                })
              ]) appCfg.defaultUsernames
            )))
        );
    };
}
