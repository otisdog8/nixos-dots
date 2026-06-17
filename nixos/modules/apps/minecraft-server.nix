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

  # Stage declarative state into the (persistent) data dir before each start:
  # ops/whitelist, server.properties overrides, symlinks (e.g. an extra mod), and
  # files (e.g. a forwarding config with @FORWARDING_SECRET@). symlinks/files are
  # tracked in .mc-managed and cleaned at the next start so removals take effect.
  mkPreStart =
    name: serverCfg:
    let
      esc = lib.escapeShellArg;
      propLines = lib.mapAttrsToList (
        k: v:
        let
          val = if lib.isBool v then lib.boolToString v else toString v;
        in
        ''
          ${pkgs.gnused}/bin/sed -i ${esc "/^${k}=/d"} server.properties
          printf '%s\n' ${esc "${k}=${val}"} >> server.properties
        ''
      ) serverCfg.serverProperties;
      symlinkLines = lib.mapAttrsToList (n: src: ''
        mkdir -p "$(dirname ${esc n})"
        ln -sfn ${esc "${src}"} ${esc n}
        printf '%s\n' ${esc n} >> .mc-managed
      '') serverCfg.symlinks;
      fileLines = lib.mapAttrsToList (n: src: ''
        mkdir -p "$(dirname ${esc n})"
        if ${pkgs.file}/bin/file --mime-encoding ${esc "${src}"} | grep -qv '\bbinary$'; then
          ${pkgs.gawk}/bin/awk '{ for (v in ENVIRON) gsub("@" v "@", ENVIRON[v]); print }' ${esc "${src}"} > ${esc n}
        else
          cp -r --dereference ${esc "${src}"} ${esc n}
        fi
        chmod -R u+w ${esc n}
        printf '%s\n' ${esc n} >> .mc-managed
      '') serverCfg.files;
    in
    pkgs.writeShellScript "mc-pre-${name}" ''
      set -eu
      if [ -e .mc-managed ]; then
        while IFS= read -r p; do [ -n "$p" ] && rm -rf "$p"; done < .mc-managed
        rm -f .mc-managed
      fi
      ${lib.optionalString (
        cfg.operators != { }
      ) "${pkgs.coreutils}/bin/install -m640 ${opsFile} ops.json"}
      ${lib.optionalString (
        cfg.whitelist != { }
      ) "${pkgs.coreutils}/bin/install -m640 ${whitelistFile} whitelist.json"}
      ${lib.optionalString (serverCfg.serverProperties != { }) "touch server.properties"}
      ${lib.concatStringsSep "\n" propLines}
      ${lib.concatStringsSep "\n" symlinkLines}
      ${lib.concatStringsSep "\n" fileLines}
    '';

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

        serverProperties = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.oneOf [
              lib.types.bool
              lib.types.int
              lib.types.str
            ]
          );
          default = { };
          example = {
            online-mode = false;
            server-ip = "127.0.0.1";
          };
          description = ''
            server.properties keys to force on each start. Merged into the
            (persistent, pack-staged) server.properties — these keys are
            overridden, the rest of the file is left alone.
          '';
        };

        symlinks = lib.mkOption {
          type = lib.types.attrsOf (lib.types.either lib.types.path lib.types.str);
          default = { };
          example = lib.literalExpression ''{ "mods/proxy-compatible-forge.jar" = pcfJar; }'';
          description = ''
            Read-only symlinks created in the data dir each start (and cleaned on
            the next start). Handy for dropping an extra mod into a staged mods/.
          '';
        };

        files = lib.mkOption {
          type = lib.types.attrsOf (lib.types.either lib.types.path lib.types.str);
          default = { };
          description = ''
            Writable files copied into the data dir each start (cleaned on the
            next start). Text files have @VAR@ placeholders substituted from
            <option>environmentFile</option> (e.g. @FORWARDING_SECRET@).
          '';
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

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Env file (var=value lines) loaded for every server. Used to provide
        secrets to mods (e.g. the forwarding secret) and to substitute @VAR@
        placeholders in per-server <option>files</option>.
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

          # Stage declarative state (ops/whitelist, server.properties overrides,
          # symlinks, files) before each start. Writable, so in-game changes work
          # for the session but reset to this on reboot.
          ExecStartPre = mkPreStart name serverCfg;

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
        // lib.optionalAttrs (cfg.environmentFile != null) {
          EnvironmentFile = cfg.environmentFile;
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
