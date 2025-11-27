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

  mkApp = appSpecModule:
    { config, lib, pkgs, inputs ? {}, ... }:
    let
      # Evaluate the app spec module to get config.app.*
      appSpec = lib.evalModules {
        modules = [ appSpecModule ];
        specialArgs = { inherit pkgs; };
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

        sandbox.enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether to sandbox ${appName} using nixpak";
        };

        sandbox.extraBinds = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Additional bind mounts for sandboxed ${appName} (relative to home or absolute paths)";
        };

        sandbox.nixpakModules = lib.mkOption {
          type = lib.types.listOf lib.types.deferredModule;
          default = [];
          description = ''
            Additional nixpak modules to merge with feature modules.
            Allows per-host nixpak configuration overrides.
          '';
        };
      }
      # Merge in custom options declared by the app
      // customOpts;

      # Generate config from the app spec
      config =
        let
          # Create sandboxed package if enabled
          sandboxedPackage = if cfg.sandbox.enable then
            let
              nixpakLib =
                if inputs ? nixpak then inputs.nixpak
                else builtins.throw "nixpak not available - add nixpak to flake inputs";
              mkNixPak = nixpakLib.lib.nixpak {
                inherit lib pkgs;
              };
            in
            (mkNixPak {
              config = { config, lib, pkgs, sloth, ... }: {
                # Compose all nixpak modules from features and user
                imports =
                  # Modules from features (gui.nix, electron.nix, etc.)
                  appCfg.nixpakModules
                  # Per-host override modules
                  ++ cfg.sandbox.nixpakModules;

                # Base configuration - set package and binPath
                app.package = cfg.package;
                app.binPath = "bin/${appCfg.packageName}";

                # Document portal for sandboxed apps
                dbus.mountDocumentPortal = lib.mkDefault true;

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
                  ++ (map (p:
                    if lib.hasPrefix "/" p then p  # Absolute path
                    else if lib.hasPrefix "." p then sloth.concat' (sloth.env "PWD") "/${p}"
		    else sloth.concat' sloth.homeDir "/${p}"  # Relative path
                  ) cfg.sandbox.extraBinds);
              };
            }).config.env
          else
            cfg.package;

          # Evaluate custom config with full nixos config
          customCfg = appCfg.customConfig { inherit config lib pkgs; };
        in
        lib.mkMerge ([
          # Base config - always applied when enabled
          (lib.mkIf cfg.enable {
            environment.systemPackages = [ sandboxedPackage ];
          })

          # System-level persistence
          (lib.mkIf (cfg.enable && appCfg.persistence.system.persist != []) {
            environment.persistence."/persist".directories = appCfg.persistence.system.persist;
          })

          (lib.mkIf (cfg.enable && appCfg.persistence.system.large != []) {
            environment.persistence."/large".directories = appCfg.persistence.system.large;
          })

          (lib.mkIf (cfg.enable && appCfg.persistence.system.cache != []) {
            environment.persistence."/cache".directories = appCfg.persistence.system.cache;
          })

          (lib.mkIf (cfg.enable && appCfg.persistence.system.baked != []) {
            environment.persistence."/baked".directories = appCfg.persistence.system.baked;
          })

          # Custom config from app spec
          (lib.mkIf cfg.enable customCfg)
        ] ++
        # User-level persistence - applied for each user in defaultUsernames
        (lib.flatten (map (username: [
          # User persistence - /persist
          (lib.mkIf (cfg.enable && cfg.persistConfig && appCfg.persistence.user.persist != []) {
            environment.persistence."/persist".users.${username}.directories =
              appCfg.persistence.user.persist;
          })

          # User persistence - /large
          (lib.mkIf (cfg.enable && cfg.persistData && appCfg.persistence.user.large != []) {
            environment.persistence."/large".users.${username}.directories =
              appCfg.persistence.user.large;
          })

          # User persistence - /cache
          (lib.mkIf (cfg.enable && cfg.enableCache && appCfg.persistence.user.cache != []) {
            environment.persistence."/cache".users.${username}.directories =
              appCfg.persistence.user.cache;
          })

          # User persistence - /baked
          (lib.mkIf (cfg.enable && appCfg.persistence.user.baked != []) {
            environment.persistence."/baked".users.${username}.directories =
              appCfg.persistence.user.baked;
          })
        ]) appCfg.defaultUsernames)));
    };
}
