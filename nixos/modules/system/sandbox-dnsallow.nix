# sbx-dnsallow (lib/dnsallow.py): sandboxes with network.allowNames reach the
# addresses those names resolve to. A root service watches systemd-resolved's
# query results and extends the sandbox's cgroup IP filter (IPAddressAllow=) as
# the names resolve. Containers (systemd backend) resolve through resolved's
# stub already; VMs with allowNames get their DNS forwarded to it by passt.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  rules = config.modules.sandbox.dnsAllow;
  configFile = pkgs.writeText "sbx-dnsallow.json" (
    builtins.toJSON {
      systemctl = "${pkgs.systemd}/bin/systemctl";
      inherit rules;
    }
  );
  dnsallow = pkgs.writeScriptBin "sbx-dnsallow" (
    "#!${pkgs.python3}/bin/python3 -IS\n" + builtins.readFile ../../../lib/dnsallow.py
  );
in
{
  options.modules.sandbox.dnsAllow = lib.mkOption {
    internal = true;
    default = [ ];
    type = lib.types.listOf (
      lib.types.submodule {
        options = {
          units = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Units (or unit globs) whose IPAddressAllow= the names extend.";
          };
          names = lib.mkOption { type = lib.types.listOf lib.types.str; };
        };
      }
    );
    description = "Name allowlists to enforce (registered by the backends).";
  };

  config = lib.mkIf (rules != [ ]) {
    assertions = [
      {
        assertion = config.services.resolved.enable;
        message = "sandbox network.allowNames needs systemd-resolved (services.resolved.enable).";
      }
    ];

    systemd.services.sbx-dnsallow = {
      description = "Open sandboxes' IP filters to their allowed names' addresses";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-resolved.service" ];
      wants = [ "systemd-resolved.service" ];
      serviceConfig = {
        ExecStart = "${dnsallow}/bin/sbx-dnsallow ${configFile}";
        Restart = "always";
        RestartSec = 2;
        # Root only for resolved's monitor (polkit) and set-property; nothing else.
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateNetwork = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" ];
        MemoryDenyWriteExecute = true;
      };
    };
  };
}
