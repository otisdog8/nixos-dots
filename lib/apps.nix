{
  # Module-based app builder
  # Takes an app spec module and generates a configurable NixOS module
  #
  # Usage:
  #   (import ../lib/apps.nix).mkApp ./my-app.nix
  #
  # Where my-app.nix is a module like:
  #   { config, lib, pkgs, ... }: {
  #     imports = [ ../lib/features/chromium.nix ../lib/features/network.nix ];
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

        # There is deliberately NO sandbox.backend override option: the effective
        # backend is app.defaultBackend (app-spec, independent eval). Dispatch can't
        # read a cfg.sandbox.* option in the mkIf conditions below without forcing
        # the outer merge mid-collect → infinite recursion (see the backendResult
        # comment). A per-host override would therefore be inert and misleading, so
        # it isn't offered — set app.defaultBackend in the app module.
        sandbox = {
          dedicatedUser = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "systemd backend only: run under a dedicated app-<name> uid.";
          };

          envMode = lib.mkOption {
            type = lib.types.enum [
              "inject"
              "defaults"
            ];
            default = "inject";
            description = "systemd env strategy: inject live session env, or derive sensible defaults.";
          };

          extraBinds = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Additional bind mounts for sandboxed ${appName}: absolute, ./ or ../ (relative to $PWD), or home-relative (see lib/paths.nix).";
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
            The final package emitted by the app's backend: the base package
            (backend "none") or a sandbox wrapper (nixpak/systemd). This is what
            gets installed in environment.systemPackages and should be used in
            customConfig.
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
          # Evaluate custom config with full nixos config
          customCfg = appCfg.customConfig { inherit config lib pkgs; };

          # ── Backend dispatch (Layer 2) ────────────────────────────────────
          # Effective backend = app.defaultBackend (see the sandbox options comment
          # for why there is no cfg.sandbox.* override).
          effectiveBackend = appCfg.defaultBackend;
          dedicated = effectiveBackend == "systemd" && cfg.sandbox.dedicatedUser;
          storage = import ./storage.nix { inherit lib; } {
            inherit appName appCfg;
            username = builtins.head appCfg.defaultUsernames;
            # nixpak/none → jrt-owned (traversable). systemd same-uid → root lock;
            # systemd + dedicatedUser → per-uid lock.
            stashOwner =
              if dedicated then
                "dedicated"
              else if effectiveBackend == "systemd" then
                "root"
              else
                "user";
            # Dedicated apps are never forced to "home" (see lib/storage.nix).
            forceHome =
              effectiveBackend == "none" || ((config.modules.sandbox.forceHomeLocation or false) && !dedicated);
          };
          backendResult = (import ./backends/default.nix).${effectiveBackend} {
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

          # app.variantCommands: extra, more-privileged entry points (e.g.
          # `claude-gpu`). Each reuses the same package and storage with the
          # variant's capability overrides and extra nixpak modules, under its own
          # command name; the regular command is unchanged.
          variantPkgs =
            if appCfg.variantCommands != { } && effectiveBackend != "nixpak" then
              builtins.throw "${appName}: variantCommands is supported only by the nixpak backend"
            else
              lib.mapAttrsToList (
                name: v:
                let
                  variant = (import ./backends/default.nix).nixpak {
                    inherit
                      appName
                      cfg
                      config
                      lib
                      pkgs
                      inputs
                      storage
                      ;
                    appCfg = appCfg // {
                      capabilities = appCfg.capabilities // v.capabilities;
                      nixpakModules = appCfg.nixpakModules ++ v.nixpakModules;
                    };
                  };
                in
                pkgs.writeShellScriptBin name ''
                  exec ${variant.package}/bin/${appCfg.packageName} "$@"
                ''
              ) appCfg.variantCommands;
        in
        lib.mkMerge [
          # Expose the final package
          {
            modules.apps.${appName}.finalPackage = finalPkg;
          }

          # Base config - always applied when enabled
          (lib.mkIf cfg.enable {
            environment.systemPackages = [ finalPkg ] ++ variantPkgs;
          })

          # Backend-emitted system config (tmpfiles, persistence, units).
          (lib.mkIf cfg.enable backendResult.systemConfig)

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
        ];
    };
}
