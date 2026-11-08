# The sandboxes' network policy at run time (lib/dnsallow.py: two root daemons).
#
# sbx-netlocal: sandboxes in the restricted network modes ("internet",
# "allowlist") stay off the host's own public addresses and its LAN's global
# prefixes, which netpolicy's static ranges can't name (an IPv6 LAN is reached
# at the router's prefix, and that changes). Those units run in netpolicy's
# slice (lib/netpolicy.nix `slice`); sbx-netlocal keeps the slice's
# IPAddressDeny= set to the current addresses and prefixes, and systemd merges
# it into every member's cgroup IP filter. Fail closed: the slice's own
# IPAddressDeny= is "any" until sbx-netlocal has set it, and the slice is
# ordered after its first update, so a member never starts with less than the
# full set. (Before that, only its own allow entries get through: its
# resolvers, say.)
#
# sbx-dnsallow: sandboxes with network.allowNames reach the addresses those
# names resolve to. It watches systemd-resolved's query results and extends the
# sandbox's cgroup IP filter (IPAddressAllow=) as the names resolve. Containers
# (systemd backend) resolve through resolved's stub already; VMs with
# allowNames get their DNS forwarded to it by passt. A unit's allow entries win
# over every deny, the slice's included, so answers in a local range
# (netpolicy's static ones, or sbx-netlocal's current set) are never opened.
#
# Each rule carries its units' static IPAddressAllow= (`allow`) too: systemd
# keeps a runtime property as a drop-in with the unit's whole list, which
# outranks the unit file until reboot, so sbx-dnsallow always writes the whole
# list (static and learned), and since the static list is in its config, a
# rebuild that changes one restarts it, and its startup pass rewrites every
# unit's drop-in to match. (A unit with restartIfChanged = false, like the
# agent VM's, still needs a restart for its other changes; its filter doesn't.)
# The broker's grant-net grants share that drop-in: sbx-attach records them
# in /run/sbx-netgrants, and every write includes them. Once no sandbox has
# allowNames left, the unit stays (on hosts with sandbox networks) as a
# oneshot that puts the units it managed back to their unit files' lists.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  netpolicy = import ../../../lib/netpolicy.nix { inherit lib; };
  rules = config.modules.sandbox.dnsAllow;
  netLocal = config.modules.sandbox.netLocal;
  stateFile = "/run/sbx-netlocal/prefixes.json";
  learnedFile = "/run/sbx-dnsallow/learned.json";
  # sbx-attach's grant-net record (lib/broker/attach.py NET_GRANTS).
  grantsDir = "/run/sbx-netgrants";

  program =
    name:
    pkgs.writeScriptBin name (
      "#!${pkgs.python3}/bin/python3 -IS\n" + builtins.readFile ../../../lib/dnsallow.py
    );
  dnsallow = program "sbx-dnsallow";
  netlocal = program "sbx-netlocal";

  dnsallowConfig = pkgs.writeText "sbx-dnsallow.json" (
    builtins.toJSON {
      systemctl = "${pkgs.systemd}/bin/systemctl";
      local = netpolicy.localCidrs;
      localFile = if netLocal.enable then stateFile else null;
      state = learnedFile;
      grants = grantsDir;
      inherit rules;
    }
  );
  netlocalConfig = pkgs.writeText "sbx-netlocal.json" (
    builtins.toJSON {
      ip = "${pkgs.iproute2}/bin/ip";
      systemctl = "${pkgs.systemd}/bin/systemctl";
      inherit (netpolicy) slice;
      state = stateFile;
      static = netpolicy.localCidrs;
      minPrefix4 = 8;
      minPrefix6 = 32;
      inherit (netLocal) widen6;
    }
  );

  # Root only for resolved's monitor (polkit) and set-property; nothing else.
  hardening = {
    CapabilityBoundingSet = "";
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
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
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" ];
    MemoryDenyWriteExecute = true;
  };
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
          deny = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "The units' policy deny entries (lib/netpolicy.nix `deny`), which the names never open.";
          };
          allow = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = ''
              The units' static IPAddressAllow= (lib/netpolicy.nix
              `ipAddressAllow`), exactly as in their unit files: sbx-dnsallow
              writes it along with the learned addresses, replacing the whole
              list each time.
            '';
          };
        };
      }
    );
    description = "Name allowlists to enforce (registered by the backends).";
  };

  options.modules.sandbox.netLocal = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default =
        lib.any (s: s.netUnits != [ ]) (lib.attrValues config.modules.sandbox.broker.sandboxes)
        || config.modules.agentVm.enable;
      defaultText = lib.literalMD "whether any sandbox or the agent VM has a network";
      description = ''
        Keep the host's public addresses and its LAN's global prefixes denied to
        sandboxes in the restricted network modes (sbx-netlocal). Off, their
        slice stays at its fail-closed default: nothing but their own allow
        entries.
      '';
    };
    widen6 = lib.mkOption {
      type = lib.types.nullOr (lib.types.ints.between 32 128);
      default = 56;
      description = ''
        Widen each IPv6 LAN prefix (usually a /64) to this many bits, to cover
        the LAN's other subnets the router routes out of the same delegated
        prefix (the ISP's other customers may fall inside too). null: exactly
        the on-link prefixes and the routes the router advertises.
      '';
    };
  };

  config = lib.mkMerge [
    {
      # Always defined: a unit naming it must never land in an implicitly
      # created, unfiltered slice.
      systemd.slices.${lib.removeSuffix ".slice" netpolicy.slice} = {
        description = "Sandboxes in a restricted network mode";
        wants = lib.optional netLocal.enable "sbx-netlocal.service";
        after = lib.optional netLocal.enable "sbx-netlocal.service";
        sliceConfig.IPAddressDeny = "any";
      };
    }

    (lib.mkIf netLocal.enable {
      systemd.services.sbx-netlocal = {
        description = "Deny sandboxes the host's and LAN's public addresses";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = hardening // {
          Type = "notify";
          ExecStart = "${netlocal}/bin/sbx-netlocal ${netlocalConfig}";
          Restart = "always";
          RestartSec = 2;
          RuntimeDirectory = "sbx-netlocal";
          RuntimeDirectoryMode = "0755";
          # Across a crash-restart the last set stays readable (and stays on the
          # slice); a stop removes it, and sbx-dnsallow then opens nothing.
          RuntimeDirectoryPreserve = "restart";
          # The host's own netlink (so no PrivateNetwork); no IP traffic at all
          # (inet sockets only in case `ip` opens one for an ioctl).
          IPAddressDeny = "any";
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_NETLINK"
            "AF_INET"
            "AF_INET6"
          ];
        };
      };
    })

    (lib.mkIf (rules != [ ]) {
      assertions = [
        {
          assertion = config.services.resolved.enable;
          message = "sandbox network.allowNames needs systemd-resolved (services.resolved.enable).";
        }
      ];
    })

    (lib.mkIf (rules != [ ] || netLocal.enable) {
      # The grants lock exists before either side needs it (sbx-attach also
      # makes it): a write that found none would race a first grant.
      systemd.tmpfiles.settings.sbx-netgrants = {
        ${grantsDir}.d = {
          mode = "0755";
          user = "root";
          group = "root";
        };
        "${grantsDir}/lock".f = {
          mode = "0644";
          user = "root";
          group = "root";
        };
      };

      systemd.services.sbx-dnsallow = {
        description =
          if rules != [ ] then
            "Open sandboxes' IP filters to their allowed names' addresses"
          else
            "Put sandboxes' IP filters back to their unit files' (no allowNames left)";
        wantedBy = [ "multi-user.target" ];
        after = [
          "systemd-tmpfiles-setup.service"
        ]
        ++ lib.optional (rules != [ ]) "systemd-resolved.service"
        ++ lib.optional netLocal.enable "sbx-netlocal.service";
        wants =
          lib.optional (rules != [ ]) "systemd-resolved.service"
          ++ lib.optional netLocal.enable "sbx-netlocal.service";
        serviceConfig = hardening // {
          PrivateNetwork = true;
          RestrictAddressFamilies = [ "AF_UNIX" ];
          # The learned addresses, kept across stops and starts (a rebuild)
          # until reboot, like the runtime drop-ins they end up in.
          RuntimeDirectory = "sbx-dnsallow";
          RuntimeDirectoryMode = "0700";
          RuntimeDirectoryPreserve = "yes";
        }
        // (
          if rules != [ ] then
            {
              ExecStart = "${dnsallow}/bin/sbx-dnsallow ${dnsallowConfig}";
              Restart = "always";
              RestartSec = 2;
            }
          else
            {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = "${dnsallow}/bin/sbx-dnsallow --cleanup ${dnsallowConfig}";
            }
        );
      };
    })
  ];
}
