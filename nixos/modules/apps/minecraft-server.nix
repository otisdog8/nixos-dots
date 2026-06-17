# Minecraft Server Module
# Minimal abstraction for sandboxed Minecraft servers, managed via tmux.
#
# Used for CurseForge/Forge modpack backends (which nix-minecraft can't package).
# Runs as the shared `mc` user so it coexists with the nix-minecraft module
# (Velocity/lobby). A polkit rule lets `mc` start/stop `minecraft-*` units, which
# is what AutoServer (inside Velocity) uses to spin backends up on demand.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  appName = "minecraft-server";
  cfg = config.modules.apps.${appName};

  tmux = "${pkgs.tmux}/bin/tmux";
  sockOf = name: "/run/minecraft/${name}.sock";

  # Operator/whitelist option shapes mirror nix-minecraft so a single global set
  # in the host config can feed both frameworks. A bare UUID string coerces to a
  # full operator (level 4).
  minecraftUUID = lib.types.strMatching "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
  operatorType = lib.types.coercedTo minecraftUUID (uuid: { inherit uuid; }) (
    lib.types.submodule {
      options = {
        uuid = lib.mkOption {
          type = minecraftUUID;
          description = "The operator's (online) UUID.";
        };
        level = lib.mkOption {
          type = lib.types.ints.between 0 4;
          default = 4;
          description = "Permission level.";
        };
        bypassesPlayerLimit = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether the operator can join past the player limit.";
        };
      };
    }
  );

  # Generated once and installed (writable) into every server's directory, so
  # ops/whitelist are a single declarative source of truth across all backends.
  opsFile = pkgs.writeText "ops.json" (
    builtins.toJSON (
      lib.mapAttrsToList (name: o: {
        inherit name;
        inherit (o) uuid level bypassesPlayerLimit;
      }) cfg.operators
    )
  );
  whitelistFile = pkgs.writeText "whitelist.json" (
    builtins.toJSON (lib.mapAttrsToList (name: uuid: { inherit name uuid; }) cfg.whitelist)
  );

  serverOpts =
    { name, ... }:
    {
      options = {
        enable = lib.mkEnableOption "this Minecraft server";

        directory = lib.mkOption {
          type = lib.types.str;
          default = "/mc/${name}";
          description = "Server directory";
        };

        javaPackage = lib.mkOption {
          type = lib.types.package;
          default = pkgs.jdk21;
          description = "Java package to use";
        };

        jvmOpts = lib.mkOption {
          type = lib.types.str;
          default = "-Xmx4G -Xms2G";
          example = "-Xmx8G -Xms4G";
          description = ''
            JVM options (heap size and flags). Set the memory here instead of a
            hand-staged user_jvm_args.txt.
          '';
        };

        jvmArgsFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "@user_jvm_args.txt";
          description = "Optional extra JVM args file (legacy; prefer jvmOpts).";
        };

        extraArgs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "@libraries/net/minecraftforge/forge/1.20.1-47.3.11/unix_args.txt" ];
          description = "Extra arguments passed to java (e.g. the Forge launcher arg file).";
        };

        modLoaderLauncher = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            For modern Forge/NeoForge modpacks. Instead of a fixed jar/args, launch
            by auto-discovering the `libraries/.../unix_args.txt` the installer
            generated (its path encodes the loader and version, which we then don't
            have to track per pack). Memory/GC come from `jvmOpts`; `jar` and
            `extraArgs` are ignored.
          '';
        };

        jar = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = "server.jar";
          description = "Server jar file (null if using extraArgs for modded).";
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 25565;
          description = ''
            Server port. Passed as `--port` on the command line, which overrides
            server.properties, so this value is authoritative.
          '';
        };

        autoStart = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Start this server at boot. Set false for on-demand backends that
            AutoServer starts when a player connects.
          '';
        };

        stopCommand = lib.mkOption {
          type = lib.types.str;
          default = "stop";
          description = ''
            Console command sent for a graceful shutdown. Use "end" for proxies.
          '';
        };

        restart = lib.mkOption {
          type = lib.types.str;
          default = "on-failure";
          description = ''
            systemd Restart= value. Use "no" for on-demand backends so it doesn't
            fight AutoServer's stop, "always" for always-on servers.
          '';
        };

        timeoutStop = lib.mkOption {
          type = lib.types.str;
          default = "120s";
          description = ''
            systemd TimeoutStopSec=. Must exceed the world-save time of the
            biggest modpack so the graceful stop completes before SIGKILL.
          '';
        };

        openFirewall = lib.mkEnableOption "opening the firewall for this server";

        sandbox.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable systemd sandboxing";
        };
      };
    };

  # Modern Forge/NeoForge packs: the installer drops a libraries/.../unix_args.txt
  # whose path encodes the loader and version. Discover it at runtime so we don't
  # track per-pack versions; memory/GC come from jvmOpts.
  mkModLauncher =
    name: serverCfg:
    pkgs.writeShellScript "mc-launch-${name}" ''
      set -euo pipefail
      unix_args=$(${pkgs.findutils}/bin/find libraries -name unix_args.txt -print -quit 2>/dev/null || true)
      if [ -z "''${unix_args:-}" ]; then
        echo "minecraft-${name}: no libraries/.../unix_args.txt under $PWD — run the Forge/NeoForge installer first." >&2
        exit 1
      fi
      exec ${serverCfg.javaPackage}/bin/java ${serverCfg.jvmOpts} "@$unix_args" --port ${toString serverCfg.port} nogui
    '';

  mkServerCommand =
    name: serverCfg:
    if serverCfg.modLoaderLauncher then
      "${pkgs.bash}/bin/bash ${mkModLauncher name serverCfg}"
    else
      let
        java = "${serverCfg.javaPackage}/bin/java";
        parts = [
          java
          serverCfg.jvmOpts
        ]
        ++ lib.optional (serverCfg.jvmArgsFile != null) serverCfg.jvmArgsFile
        ++ serverCfg.extraArgs
        ++ lib.optional (serverCfg.jar != null) "-jar ${serverCfg.jar}"
        ++ [
          "--port ${toString serverCfg.port}"
          "nogui"
        ];
      in
      lib.concatStringsSep " " (lib.filter (s: s != "") parts);

  enabledServers = lib.filterAttrs (_: s: s.enable) cfg.servers;

in
{
  options.modules.apps.${appName} = {
    enable = lib.mkEnableOption "Minecraft server management";

    servers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule serverOpts);
      default = { };
      description = "Minecraft server instances";
    };

    operators = lib.mkOption {
      type = lib.types.attrsOf operatorType;
      default = { };
      example = lib.literalExpression ''
        {
          jacob = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx";
          friend = {
            uuid = "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy";
            level = 2;
          };
        }
      '';
      description = ''
        Operators (ops.json) applied to every server managed by this module.
        Use online (Mojang) UUIDs, since modern forwarding passes them through.
      '';
    };

    whitelist = lib.mkOption {
      type = lib.types.attrsOf minecraftUUID;
      default = { };
      description = ''
        Whitelisted players (whitelist.json) applied to every server managed by
        this module. Each server's server.properties must set white-list=true for
        this to be enforced.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.mc = {
      isSystemUser = true;
      description = "Minecraft Servers";
      group = "mc";
      home = "/mc";
      shell = pkgs.bash;
    };
    users.groups.mc = { };

    # tmux on the system PATH so admins (root / mc / members of the mc group) can
    # attach to a server console: `tmux -S /run/minecraft/<name>.sock attach`.
    environment.systemPackages = [ pkgs.tmux ];

    # Let the `mc` user manage minecraft-* units without sudo. This is what
    # AutoServer (running inside Velocity as `mc`) uses to start/stop backends.
    # Matches both `minecraft-<name>` (this module) and `minecraft-server-<name>`
    # (nix-minecraft). With system services, PrivateUsers keeps the mc identity
    # intact (only other users collapse to nobody), so the rule applies.
    security.polkit.enable = true;
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            subject.user == "mc") {
          var unit = action.lookup("unit");
          if (unit && unit.indexOf("minecraft-") == 0) {
            return polkit.Result.YES;
          }
        }
      });
    '';

    systemd.services = lib.mapAttrs' (
      name: serverCfg:
      let
        sock = sockOf name;
      in
      lib.nameValuePair "minecraft-${name}" {
        description = "Minecraft Server - ${name}";
        after = [ "network.target" ];
        wantedBy = lib.optional serverCfg.autoStart "multi-user.target";

        serviceConfig = {
          Type = "forking";
          GuessMainPID = true;

          # Refresh the declarative ops/whitelist before each start (writable, so
          # in-game /op still works for the session but resets to this on reboot).
          ExecStartPre = pkgs.writeShellScript "mc-pre-${name}" ''
            ${lib.optionalString (
              cfg.operators != { }
            ) "${pkgs.coreutils}/bin/install -m640 ${opsFile} ops.json"}
            ${lib.optionalString (
              cfg.whitelist != { }
            ) "${pkgs.coreutils}/bin/install -m640 ${whitelistFile} whitelist.json"}
          '';

          ExecStart = pkgs.writeShellScript "mc-start-${name}" ''
            ${tmux} -S ${sock} new-session -d ${mkServerCommand name serverCfg}
            # PrivateUsers maps other users to nobody; restore tmux access so
            # members of the mc group can still attach to the console.
            ${tmux} -S ${sock} server-access -aw nobody
          '';

          ExecStartPost = pkgs.writeShellScript "mc-start-post-${name}" ''
            ${pkgs.coreutils}/bin/chmod 660 ${sock}
          '';

          # Graceful shutdown: save the world, send the stop command, then wait
          # for the session to actually exit (no fixed sleep, no premature kill).
          ExecStop = pkgs.writeShellScript "mc-stop-${name}" ''
            if ! ${tmux} -S ${sock} has-session 2>/dev/null; then
              exit 0
            fi
            ${tmux} -S ${sock} send-keys C-u save-all Enter
            sleep 5
            ${tmux} -S ${sock} send-keys C-u ${lib.escapeShellArg serverCfg.stopCommand} Enter
            while ${tmux} -S ${sock} has-session 2>/dev/null; do sleep 1; done
          '';

          User = "mc";
          Group = "mc";
          WorkingDirectory = serverCfg.directory;
          Restart = serverCfg.restart;
          RestartSec = "30s";
          TimeoutStopSec = serverCfg.timeoutStop;

          # Shared with the nix-minecraft module; sockets are named per server.
          RuntimeDirectory = "minecraft";
          RuntimeDirectoryPreserve = "yes";
        }
        // lib.optionalAttrs serverCfg.sandbox.enable {
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          ReadWritePaths = [ serverCfg.directory ];
          NoNewPrivileges = true;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          PrivateUsers = true;
        };
      }
    ) enabledServers;

    networking.firewall = {
      allowedTCPPorts = lib.flatten (
        lib.mapAttrsToList (_: s: lib.optional s.openFirewall s.port) enabledServers
      );
      allowedUDPPorts = lib.flatten (
        lib.mapAttrsToList (_: s: lib.optional s.openFirewall s.port) enabledServers
      );
    };

  };
}
