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
          # Selecting container vs vm is a VALUE choice (which package the command
          # is), never a structural one: both implementations are always evaluated,
          # so reading this option can't recurse into the config merge the way a
          # backend override would (see above).
          mode = lib.mkOption {
            type = lib.types.enum [
              "container"
              "vm"
            ];
            default = config.modules.sandbox.mode;
            defaultText = lib.literalExpression "config.modules.sandbox.mode";
            description = "Run ${appName} in its container backend (app.defaultBackend) or its microVM.";
          };

          # Per-host override of app.capabilities.networkPolicy (lib/netpolicy.nix).
          network = {
            mode = lib.mkOption {
              type = lib.types.enum [
                "default"
                "open"
                "internet"
                "allowlist"
              ];
              default = appCfg.capabilities.networkPolicy.mode;
              description = "Where ${appName} may connect (see app.capabilities.networkPolicy.mode).";
            };
            allow = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = appCfg.capabilities.networkPolicy.allow;
              description = "Addresses/prefixes ${appName} may always reach.";
            };
            deny = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = appCfg.capabilities.networkPolicy.deny;
              description = "Addresses/prefixes ${appName} may never reach.";
            };
            allowDns = lib.mkOption {
              type = lib.types.bool;
              default = appCfg.capabilities.networkPolicy.allowDns;
              description = "Keep ${appName}'s resolver reachable in the restricted modes.";
            };
            allowNames = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = appCfg.capabilities.networkPolicy.allowNames;
              description = "Names whose addresses ${appName} may reach (see app.capabilities.networkPolicy.allowNames).";
            };
          };

          vm = {
            persistent = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Keep ${appName}'s VM running after its last session exits (stop it with `sandbox-vm stop ${appName}`).";
            };
            memory = lib.mkOption {
              type = lib.types.ints.positive;
              default = 4096;
              description = "Guest memory for ${appName}'s VM, in MiB.";
            };
            vcpus = lib.mkOption {
              type = lib.types.ints.positive;
              default = 4;
              description = "vCPUs for ${appName}'s VM.";
            };
            gpuMemoryMiB = lib.mkOption {
              type = lib.types.addCheck (lib.types.ints.between 256 65536) (n: lib.mod n 64 == 0);
              default = 1024;
              description = "virtio-nvgpu's shared window for ${appName}'s VM, in MiB (a multiple of 64, 256-65536; at most 64512 for GPU-compute VMs): how much GPU memory its processes may keep CPU-mapped at once (the backend's --window-size). It is address space, not guest RAM or VRAM. Keep the default unless the backend logs `SHM alloc failed` (the fork's DEPLOY.md, \"Sizing the window\"). Group members use their group's setting.";
            };
            gpuMemoryProcessPercent = lib.mkOption {
              type = lib.types.ints.between 1 95;
              default = 50;
              description = "How much of each zone of the shared window one guest process may hold, in percent (the fork's default is 50). Above 50, one process can leave the VM's other processes only the reserve, which is shrunk to what the share leaves. Suits a single-game VM, not a VM shared by several apps. A non-default value builds a backend variant. Group members use their group's setting.";
            };
            tuning = lib.mkOption {
              type = lib.types.enum [
                "default"
                "game"
              ];
              default = "default";
              description = ''
                "game": virtio-nvgpu's measured settings for games, for a GPU VM
                (lib/vm/instance.nix `gameTuning`): a 100 µs scheduler slice for
                the VMM, one core-scheduling cookie for the VMM and its backend,
                the vCPUs pinned in pairs on whole cores of the CPU's
                least-preferred L3 domain (an even vcpus count; else unpinned),
                and transparent huge pages and ntsync in the guest. Group
                members use their group's setting.'';
            };
            x11 = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Give ${appName}'s VM an X server of its own (xwayland-satellite
                in the guest, DISPLAY=:0), for an app that needs X11 beside
                Wayland. Nothing of the host's X server is shared, unlike
                sandbox.x11Forward, and the container is unaffected.'';
            };
            clipboard = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                For an app that copies through the data-control protocols
                (wlr/ext-data-control) instead of the ordinary Wayland
                clipboard: its VM gets a data-control endpoint
                (lib/vm/clip-guest.py) whose copies the host's broker puts
                on your clipboard, without asking. The VM can set and clear
                the clipboard, never read it. Text only; VM mode only.'';
            };
            hostKeyring = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Let ${appName}'s VM talk to the host's Secret Service
                (org.freedesktop.secrets: kwallet) through its filtered session
                bus. That is every unlocked collection the host keyring serves,
                not just ${appName}'s own entries: grant it only to an app as
                trusted with your secrets as the keyring itself. VM mode only,
                and not for group members.'';
            };
            nested = lib.mkOption {
              type = lib.types.bool;
              default = config.modules.sandbox.vm.nested;
              defaultText = lib.literalExpression "config.modules.sandbox.vm.nested";
              description = "Inside its VM, also run ${appName} in its nixpak sandbox (defense in depth).";
            };
            cameraOnLaunch = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Apps with the camera capability (container or VM): ask (through the broker) to attach the camera when ${appName} starts. Otherwise: `sbx-request camera` inside, or for a VM `sandbox-vm camera ${appName}`.";
            };
            # Hooks for other modules (e.g. op-broker) to reach into the guest.
            relays = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    host = lib.mkOption {
                      type = lib.types.str;
                      description = "Host unix socket the service connects to (as the user).";
                    };
                    guest = lib.mkOption {
                      type = lib.types.str;
                      description = "Where the guest's end listens.";
                    };
                  };
                }
              );
              default = { };
              description = "Extra host services relayed into ${appName}'s VM over vsock, by service name.";
            };
            guestBinds = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              example = {
                "~/.mozilla/native-messaging-hosts/x.json" = "/nix/store/…/x.json";
              };
              description = "Read-only binds in ${appName}'s guest: target (absolute or ~/…) = source (a store path).";
            };
            guestServices = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    argv = lib.mkOption { type = lib.types.listOf lib.types.str; };
                    group = lib.mkOption {
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                      description = "Run with this primary group (created in the guest if missing).";
                    };
                    root = lib.mkOption {
                      type = lib.types.bool;
                      default = false;
                      description = "Run as the guest's root instead of the user (the guest is the boundary; e.g. a polkit agent, or a helper that drops privileges itself).";
                    };
                  };
                }
              );
              default = { };
              description = "Commands ${appName}'s guest keeps running as the user, or as root (with the VM's display, when it has one).";
            };
          };

          dedicatedUser = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "systemd backend only: run under a dedicated app-<name> uid.";
          };

          appearAsUser = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              systemd backend + dedicatedUser: inside its sandbox the app sees
              itself as the user (uid and gid, HOME=/home/<user>, the user's
              runtime dir path), as it does in its VM, while the host still runs
              it as app-<name>. Paths the app saves are then the same in container
              and VM mode. Its old home path stays bound to the same data.
            '';
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

          extraBindsReadOnly = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Like extraBinds, but read-only. Not for dedicated-uid apps (the systemd backend's ACL grants are read-write).";
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
              home (or, in its VM, the guest's tmpfs). The launcher ACL-grants the app
              uid on that subdir. Container and VM mode.
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
            The app's primary package, for sandbox.mode: the container backend's
            (the base package for "none", a nixpak/systemd wrapper otherwise) or the
            VM launcher. This is what gets installed in environment.systemPackages
            and should be used in customConfig.
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
            username = appCfg.username;
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
          # The container implementation (app.defaultBackend). It owns the app's
          # storage lowering (tmpfiles, persistence, and the
          # dedicated uid), which the VM implementation then reuses as-is.
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

          # The VM implementation, always evaluated next to it (lazily: nothing of
          # it is built unless the app runs in a VM or variants are on). Its VMM
          # runs as whoever owns the stash, so both implementations share one copy
          # of the app's data.
          username = appCfg.username;
          vmResult = import ./backends/vm.nix {
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
            principal = if dedicated then "app-${appName}" else username;
            principalGroup = if dedicated then "app-${appName}" else config.users.users.${username}.group;
            desktopSource = backendResult.package;
            inherit (backendResult) dbusArgs flatpakInfoFile appId;
          };

          implLock = import ./impl-lock.nix { inherit lib pkgs; };
          lockArgs = {
            backend = effectiveBackend;
            inherit (storage) entries;
            inherit (appCfg) multiInstance;
          };

          variants = import ./variants.nix { inherit lib pkgs; };
          variantsOn = config.modules.sandbox.variants.enable;
          vmWanted = cfg.sandbox.mode == "vm" || variantsOn;
          # app.groupCommand in a group VM: the regular command stays the
          # container's, and the group command enters the VM.
          inGroup = lib.any (g: lib.elem appName g.apps) (lib.attrValues config.modules.sandbox.groups);
          groupVm = cfg.sandbox.mode == "vm" && appCfg.groupCommand != null && inGroup;
          selectedPkg =
            if groupVm then
              pkgs.symlinkJoin {
                inherit (backendResult.package) name;
                paths = [ backendResult.package ];
                postBuild = ''
                  ln -s ${vmResult.package}/bin/${appCfg.packageName} "$out/bin/${appCfg.groupCommand}"
                '';
              }
            else if cfg.sandbox.mode == "vm" then
              vmResult.package
            else
              backendResult.package;
          # With variants on, the launcher lists "<App> (container)" / "<App> (vm)"
          # instead of the plain entry, which stays for MIME/default-browser use.
          finalPkg = if variantsOn then variants.hideDesktop selectedPkg else selectedPkg;
          implVariants = [
            (variants.mkVariant {
              inherit appName;
              pkg = backendResult.package;
              bin = appCfg.packageName;
              suffix = if effectiveBackend == "none" then "host" else "container";
              label = if effectiveBackend == "none" then "host" else "container";
            })
            (variants.mkVariant {
              inherit appName;
              pkg = vmResult.package;
              bin = appCfg.packageName;
              suffix = "vm";
              label = "vm";
            })
          ];

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
                    joinGroup = false;
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
            environment.systemPackages = [
              finalPkg
            ]
            ++ variantPkgs
            ++ lib.optionals variantsOn implVariants;
          })

          # The container and the VM share the app's data: whichever runs locks
          # the other out (lib/impl-lock.nix).
          (lib.mkIf (cfg.enable && implLock.wanted lockArgs) {
            systemd.tmpfiles.settings."10-sandbox-impl" = implLock.tmpfiles appName;
          })

          # Backend-emitted system config (tmpfiles, persistence, units).
          (lib.mkIf cfg.enable backendResult.systemConfig)
          (lib.mkIf (cfg.enable && vmWanted) vmResult.systemConfig)

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
