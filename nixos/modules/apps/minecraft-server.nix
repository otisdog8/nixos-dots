# Minecraft Server Module
# Minimal abstraction for sandboxed Minecraft servers using screen
{
  config,
  lib,
  pkgs,
  ...
}:

let
  appName = "minecraft-server";
  cfg = config.modules.apps.${appName};

  serverOpts =
    { name, config, ... }:
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

        jvmArgsFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "@user_jvm_args.txt";
          description = "JVM args file (for modded servers)";
        };

        extraArgs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "@libraries/net/minecraftforge/forge/1.20.1-47.3.11/unix_args.txt" ];
          description = "Extra arguments passed to java";
        };

        jar = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = "server.jar";
          description = "Server jar file (null if using extraArgs for modded)";
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 25565;
          description = "Server port";
        };

        openFirewall = lib.mkEnableOption "opening firewall for this server";

        sandbox.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable systemd sandboxing";
        };
      };
    };

  mkServerCommand =
    name: serverCfg:
    let
      java = "${serverCfg.javaPackage}/bin/java";
      jvmArgs = lib.optionalString (serverCfg.jvmArgsFile != null) serverCfg.jvmArgsFile;
      jarArg = lib.optionalString (serverCfg.jar != null) "-jar ${serverCfg.jar}";
      extras = lib.concatStringsSep " " serverCfg.extraArgs;
    in
    "${java} ${jvmArgs} ${extras} ${jarArg} nogui";

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

    systemd.services = lib.mapAttrs' (
      name: serverCfg:
      lib.nameValuePair "minecraft-${name}" (
        lib.mkIf serverCfg.enable {
          description = "Minecraft Server - ${name}";
          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            ExecStart = "${pkgs.screen}/bin/screen -DmS mc-${name} ${mkServerCommand name serverCfg}";
            ExecStop = pkgs.writeShellScript "mc-stop-${name}" ''
              ${pkgs.screen}/bin/screen -S mc-${name} -X stuff "save-all^M"
              sleep 5
              ${pkgs.screen}/bin/screen -S mc-${name} -X stuff "stop^M"
              sleep 10
            '';
            User = "mc";
            Group = "mc";
            WorkingDirectory = serverCfg.directory;
            Restart = "on-failure";
            RestartSec = "30s";
          }
          // lib.optionalAttrs serverCfg.sandbox.enable {
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            PrivateDevices = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectControlGroups = true;
            ReadWritePaths = [
              serverCfg.directory
              "/mc/.screen"
            ];
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
      )
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
