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
  python = "${pkgs.python3}/bin/python3 -IS";
  brokerPkg = pkgs.writeScriptBin "sbx-broker" (
    "#!${python}\n" + builtins.readFile ../../../lib/broker/broker.py
  );
  requestPkg = pkgs.writeScriptBin "sbx-request" (
    "#!${python}\n" + builtins.readFile ../../../lib/broker/request.py
  );

  brokerConfig = pkgs.writeText "sbx-broker.json" (
    builtins.toJSON {
      prompt = "${prompt}/bin/sbx-prompt";
      run0 = "${pkgs.systemd}/bin/run0";
      systemctl = "${pkgs.systemd}/bin/systemctl";
      setfacl = "${pkgs.acl}/bin/setfacl";
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
          };
        }
      );
      description = "Every sandbox the broker serves (registered by the backends).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      requestPkg
      prompt
    ];

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
