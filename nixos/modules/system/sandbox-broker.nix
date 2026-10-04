# sbx-broker: controlled sandbox escapes and temporary grants, each approved by
# the user in a desktop dialog (lib/broker/broker.py, lib/broker/prompt.nix).
#
# Every sandbox gets its own broker socket, $XDG_RUNTIME_DIR/sbx-broker/<name>.sock,
# which the backends put at /run/sbx/broker.sock inside it (bound into
# containers; relayed into VMs over their vsock relay). The socket IS the
# requester's identity. Inside, `sbx-request` asks for:
#   exec [--root] CMD…     run CMD outside the sandbox as the user (root: through
#                          run0/polkit, never remembered for the session)
#   grant-net ADDR         let the sandbox reach an address its network policy
#                          blocks (VMs and systemd-backend apps; until it stops)
#   grant-path [--write] P give a running VM a folder (see the VM instances)
#   camera                 attach the host's camera(s) to a running VM
#   fido                   (VMs' virtual security key, not sbx-request) relay
#                          CTAPHID to the key plugged in now
#   authenticate ACTION    (VM guests' polkit agent, not sbx-request) have the
#                          user authenticate on the host, through their own
#                          polkit agent, for a mapped host action (authActions)
# Sandboxes with audio also get <name>.pulse, a PulseAudio socket in front of the
# user's (in place of pulse/native in containers; the VM relay's pulse service):
# playback passes, recording asks (op "microphone" for rules) and only for
# sandboxes with the microphone capability, and commands that reconfigure the
# server or touch other clients are refused.
# Anything no rule covers is a prompt; the answer can cover the rest of the login
# session (capped at 12 h), except root commands.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.sandbox.broker;
  user = config.modules.sandbox.vm.user;

  ruleType = lib.types.submodule {
    options = {
      op = lib.mkOption {
        type = lib.types.enum [
          "exec"
          "grant-net"
          "grant-path"
          "fido"
          "camera"
          "microphone"
        ];
        default = "exec";
      };
      as = lib.mkOption {
        type = lib.types.enum [
          "user"
          "root"
        ];
        default = "user";
        description = "exec only: who the command runs as.";
      };
      argv = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "exec only: the command (a prefix, or exact with match = \"exact\").";
      };
      match = lib.mkOption {
        type = lib.types.enum [
          "prefix"
          "exact"
        ];
        default = "prefix";
      };
      action = lib.mkOption {
        type = lib.types.enum [
          "allow"
          "prompt"
          "deny"
        ];
      };
    };
  };

  prompt = import ../../../lib/broker/prompt.nix pkgs;

  # The host actions the authenticate op checks (share/polkit-1/actions, linked
  # into the system profile where polkitd reads actions).
  authPolicy = pkgs.writeTextDir "share/polkit-1/actions/org.otisroot.sandbox.policy" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE policyconfig PUBLIC
     "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
     "http://www.freedesktop.org/standards/PolicyKit/1.0/policyconfig.dtd">
    <policyconfig>
    ${lib.concatStrings (
      lib.mapAttrsToList (id: a: ''
        <action id="${lib.escapeXML id}">
          <description>${lib.escapeXML a.description}</description>
          <message>${lib.escapeXML a.message}</message>
          <defaults>
            <allow_any>no</allow_any>
            <allow_inactive>no</allow_inactive>
            <allow_active>auth_self</allow_active>
          </defaults>
        </action>
      '') cfg.authActions
    )}
    </policyconfig>
  '';
  python = "${pkgs.python3}/bin/python3 -IS";
  brokerPkg = pkgs.writeScriptBin "sbx-broker" (
    "#!${python}\n" + builtins.readFile ../../../lib/broker/broker.py
  );
  requestPkg = pkgs.writeScriptBin "sbx-request" (
    "#!${python}\n" + builtins.readFile ../../../lib/broker/request.py
  );

  # The root side of container grants and camera attach (lib/broker/attach.py).
  attach = import ../../../lib/broker/attach.nix pkgs;
  hostUser = config.users.users.${user};
  attachConfig = pkgs.writeText "sbx-attach.json" (
    builtins.toJSON {
      user = {
        name = user;
        uid = hostUser.uid;
        gid = config.users.groups.${hostUser.group}.gid;
        home = hostUser.home;
        runtimeDir = "/run/user/${toString hostUser.uid}";
      };
      setfacl = "${pkgs.acl}/bin/setfacl";
      sandboxes = cfg.attach;
      vms = cfg.attachVms;
    }
  );

  brokerConfig = pkgs.writeText "sbx-broker.json" (
    builtins.toJSON {
      prompt = "${prompt}/bin/sbx-prompt";
      run0 = "${pkgs.systemd}/bin/run0";
      systemctl = "${pkgs.systemd}/bin/systemctl";
      setfacl = "${pkgs.acl}/bin/setfacl";
      pkcheck = "${config.security.polkit.package.bin}/bin/pkcheck";
      sandboxes = lib.mapAttrs (
        name: sb:
        sb
        // {
          rules = cfg.rules.${name} or [ ] ++ cfg.defaultRules;
        }
      ) cfg.sandboxes;
    }
  );
in
{
  options.modules.sandbox.broker = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run sbx-broker in the user's session, and give sandboxes a socket to it.";
    };

    rules = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf ruleType);
      default = { };
      example = lib.literalExpression ''
        {
          vm-group-agents = [
            { argv = [ "git" "push" ]; action = "prompt"; }
            { argv = [ "nixos-rebuild" ]; as = "root"; action = "deny"; }
          ];
        }
      '';
      description = ''
        Per-sandbox rules, first match wins; unmatched requests prompt. Sandbox
        names: the app name for its container, vm-<app> for its VM,
        vm-group-<group> for a group's VM.
      '';
    };

    defaultRules = lib.mkOption {
      type = lib.types.listOf ruleType;
      default = [ ];
      description = "Rules for every sandbox, after its own.";
    };

    attach = lib.mkOption {
      default = { };
      description = ''
        Containers the root attach helper (lib/broker/attach.py) may bind into
        while they run: a granted folder (`paths`, only for sandboxes that run
        as the user) and the host's UVC cameras (`camera`). Filled in by the
        container backends; their broker entries point grantPaths/camera at it.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            appId = lib.mkOption {
              type = lib.types.str;
              description = "The sandbox's flatpak app id (its /.flatpak-info), how its instances are recognised.";
            };
            appUser = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "A dedicated uid the sandbox runs as (its runtime dir is /run/<appUser>); null: the user.";
            };
            unit = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "The system unit its processes must be in (systemd backend).";
            };
            paths = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
            camera = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
          };
        }
      );
    };

    attachVms = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Sandbox VM instances whose folder grants the attach helper mounts (into their grants share's jail).";
    };

    sandboxes = lib.mkOption {
      internal = true;
      default = { };
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            label = lib.mkOption { type = lib.types.str; };
            uid = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "A dedicated uid that must be able to connect (ACL on the socket).";
            };
            netUnits = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Units (or unit globs) whose IPAddressAllow= grant-net extends.";
            };
            grantPaths = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Program that attaches a folder to the running sandbox (grant-path).";
            };
            audio = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.enum [
                  "playback"
                  "microphone"
                ]
              );
              default = null;
              description = "The sandbox's PulseAudio socket (<name>.pulse): playback only, or recording too after approval.";
            };
            camera = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Program that attaches the host's camera(s) to the running sandbox (`PROG attach`).";
            };
            fido = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "The sandbox may ask to use the plugged-in security key (fido).";
            };
            authenticate = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              example = {
                "com.1password.1Password.unlock" = "org.otisroot.sandbox.onepassword.unlock";
              };
              description = ''
                The sandbox's polkit actions it may ask the host user to
                authenticate for (the `authenticate` op, used by the guest polkit
                agent of a VM), each mapped to the host action (from authActions)
                whose message the user's own polkit agent shows.
              '';
            };
          };
        }
      );
      description = "Every sandbox the broker serves (registered by the backends).";
    };

    authActions = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            description = lib.mkOption { type = lib.types.str; };
            message = lib.mkOption {
              type = lib.types.str;
              description = "What the user's polkit agent shows (static: nothing from the sandbox).";
            };
          };
        }
      );
      default = { };
      description = ''
        Host polkit actions (id -> text) that stand for a sandbox's own polkit
        actions in `sandboxes.<name>.authenticate`. Each is auth_self for the
        active session and nothing else, never "keep": one authentication per
        request.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      requestPkg
      prompt
    ]
    ++ lib.optional (cfg.authActions != { }) authPolicy;

    # The authenticate op checks the host actions with pkcheck.
    security.polkit.enable = lib.mkIf (cfg.authActions != { }) true;

    systemd.user.services.sbx-broker = {
      description = "Sandbox broker (escapes and grants, approved per request)";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      unitConfig.ConditionUser = user;
      serviceConfig = {
        ExecStart = "${brokerPkg}/bin/sbx-broker ${brokerConfig}";
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    # The attach helper: root, one process per request, on a socket only the
    # user can connect to. Root because cloning a host mount into another
    # namespace needs it; what it agrees to do is in attach.py's header.
    systemd.sockets.sbx-attach = lib.mkIf (cfg.attach != { } || cfg.attachVms != [ ]) {
      description = "Sandbox attach helper (folders and cameras into running containers)";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "/run/sbx-attach.sock" ];
      socketConfig = {
        Accept = true;
        SocketUser = user;
        SocketMode = "0600";
        MaxConnections = 16;
      };
    };
    systemd.services."sbx-attach@" = lib.mkIf (cfg.attach != { } || cfg.attachVms != [ ]) {
      description = "Sandbox attach request";
      serviceConfig = {
        ExecStart = "${attach.daemon}/bin/sbx-attach ${attachConfig}";
        StandardInput = "socket";
        StandardOutput = "journal";
        StandardError = "journal";
        TimeoutSec = 30;
        # open_tree/setns/move_mount, setns's chroot check, dropping to the user
        # to open the source, reading other uids' /proc entries and runtime
        # dirs, pidfd signal 0, the device ACL, chown of new mount points.
        CapabilityBoundingSet = [
          "CAP_SYS_ADMIN"
          "CAP_SYS_CHROOT"
          "CAP_SETUID"
          "CAP_SETGID"
          "CAP_DAC_READ_SEARCH"
          "CAP_DAC_OVERRIDE"
          "CAP_SYS_PTRACE"
          "CAP_KILL"
          "CAP_FOWNER"
          "CAP_CHOWN"
        ];
        NoNewPrivileges = true;
        # Not ProtectSystem/ProtectHome/PrivateMounts: sources are cloned from
        # this process's own mount namespace, which must be the host's as is
        # (a read-only remount here would make every grant read-only), nor
        # anything else that gives the unit its own mount namespace.
        RestrictAddressFamilies = [ "AF_UNIX" ];
        LockPersonality = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        LimitCORE = 0;
      };
    };

    # grant-net extends a running unit's IPAddressAllow= (systemctl set-property):
    # allowed for exactly the registered units, and nothing else.
    modules.sandbox.propertyUnits = lib.concatMap (
      sb: lib.filter (u: !(lib.hasInfix "*" u)) sb.netUnits
    ) (lib.attrValues cfg.sandboxes);
    modules.sandbox.propertyTemplates = lib.concatMap (
      sb: map (u: lib.head (lib.splitString "*" u)) (lib.filter (u: lib.hasInfix "*" u) sb.netUnits)
    ) (lib.attrValues cfg.sandboxes);
  };
}
