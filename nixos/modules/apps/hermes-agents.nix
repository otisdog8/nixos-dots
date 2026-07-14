# hermes-agents — instanced wrapper around the upstream hermes-agent package.
#
# Upstream's NixOS module (inputs.hermes-agent → nix/nixosModules.nix) is
# single-instance by design: one `hermes` user, one `hermes-agent.service`,
# one stateDir. We want one zone per agent (user/group/stateDir/unit all named
# for the AGENT, not the runtime), so this module re-implements the native
# systemd mode of the upstream module as `modules.apps.hermes-agents.
# instances.<name>`. The config-generation logic (deep-merged settings →
# config.yaml via their merge script, .env seeding, .managed marker) is
# lifted from upstream so `hermes` binaries behave identically; container
# mode, documents, plugins, and host-CLI sharing are deliberately dropped.
#
# Per instance this creates:
#   - user/group <name> with home = stateDir (default /var/lib/<name>)
#   - <name>.service           — the gateway (messaging channels, cron, agent)
#   - <name>-dashboard.service — optional web dashboard on 127.0.0.1
#   - config.yaml deep-merged from `settings` on activation (Nix keys win,
#     agent-added keys survive), .managed marker (HERMES_MANAGED drift guard)
#   - $HERMES_HOME/.env seeded from `environment` + `environmentFiles` (sops)
#   - /persist impermanence entry (opt-out via persist = false)
#
# The split that matters: everything in `settings`/`environment` is policy and
# lives in the nix store — the agent cannot self-grant capabilities. Memory,
# skills, sessions, and OAuth token stores live in stateDir and are the
# agent's to mutate. Codex OAuth is a manual one-time login per instance (see
# the runbook in the host file); the rotating auth store stays in stateDir.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.modules.apps.hermes-agents;

  defaultPackage = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
  configMergeScript = pkgs.callPackage "${inputs.hermes-agent}/nix/configMergeScript.nix" { };

  # Upstream's deep-merge settings type: attrsets from multiple definitions
  # merge recursively instead of clobbering whole top-level keys.
  deepConfigType = lib.types.mkOptionType {
    name = "hermes-config-attrs";
    description = "Hermes YAML config (attrset), merged deeply via lib.recursiveUpdate.";
    check = builtins.isAttrs;
    merge = _loc: defs: lib.foldl' lib.recursiveUpdate { } (map (d: d.value) defs);
  };

  instances = lib.filterAttrs (_: i: i.enable) cfg.instances;

  # Units are named exactly after the instance — the zone name IS the agent
  # name (e.g. hermes-homelab-recusant.service). Put the runtime in the
  # instance name if you want it visible; the module adds no prefix.
  serviceName = name: name;

  instanceModule = lib.types.submodule (
    { name, config, ... }:
    {
      options = with lib; {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable this agent instance.";
        };

        package = mkOption {
          type = types.package;
          default = defaultPackage;
          defaultText = literalExpression "inputs.hermes-agent.packages.<system>.default";
          description = "hermes-agent package for this instance.";
        };

        settings = mkOption {
          type = deepConfigType;
          default = { };
          description = ''
            Declarative Hermes config, rendered to config.yaml (nix store →
            merged over the live file on activation; Nix keys win). Policy
            only — never secrets (it is world-readable in the store).
          '';
        };

        environment = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = ''
            Non-secret environment, merged into $HERMES_HOME/.env at
            activation. Secrets go in environmentFiles.
          '';
        };

        environmentFiles = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Secret env files (sops paths), appended to $HERMES_HOME/.env at activation.";
        };

        stateDir = mkOption {
          type = types.str;
          default = "/var/lib/${name}";
          description = "Zone root: HERMES_HOME, workspace, and OAuth stores live under here.";
        };

        workingDirectory = mkOption {
          type = types.str;
          default = "/var/lib/${name}/workspace";
          description = "Agent workspace.";
        };

        extraPackages = mkOption {
          type = types.listOf types.package;
          default = [ ];
          description = "Extra tools on the service PATH (shell tool, skills, cron all see them).";
        };

        extraArgs = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Extra arguments for `hermes gateway`.";
        };

        dashboard = {
          enable = mkEnableOption "the web dashboard for this instance (<name>-dashboard.service)";
          port = mkOption {
            type = types.port;
            example = 9119;
            description = "Dashboard port (reverse-proxy it; never expose raw).";
          };
          host = mkOption {
            type = types.str;
            default = "127.0.0.1";
            description = ''
              Dashboard bind address. Loopback = no auth gate (operator-owned).
              Any non-loopback bind engages the auth gate and FAILS CLOSED
              unless an auth provider (settings.dashboard.oauth / basic_auth)
              is configured. The Host-header guard then requires requests to
              carry exactly this host — point the reverse proxy at it directly
              so nginx's default Host ($proxy_host) matches.
            '';
          };
        };

        persist = mkOption {
          type = types.bool;
          default = true;
          description = "Add stateDir to the /persist impermanence set.";
        };

        serviceConfig = mkOption {
          type = types.attrs;
          default = { };
          description = "Extra/override serviceConfig for the gateway unit (hardening tweaks, bwrap wrappers).";
        };
      };
    }
  );

  # ── Per-instance generated artifacts ─────────────────────────────────────
  generatedConfigFile =
    name: inst: pkgs.writeText "${name}-config.yaml" (builtins.toJSON inst.settings);

  envFileContent =
    inst: lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "${k}=${v}") inst.environment);

  # Config + env seeding, lifted from upstream's activation script — but run as
  # the AGENT uid, not root. The old root activation script wrote (mkdir/chown/
  # chmod/merge/touch/install/cat) through stateDir/.hermes, which the agent OWNS
  # (0750 agent:agent): a compromised agent could swap any of those paths for a
  # symlink and root would follow it — chown'ing or writing an arbitrary target
  # (a direct root escalation). Running as the agent removes the confused deputy:
  # every write below can only reach files the agent's own uid can already reach
  # (a swapped symlink is DAC-denied off-tree). Dirs are pre-created symlink-safely
  # by systemd-tmpfiles; sops secrets arrive via systemd LoadCredential (root reads
  # them into a per-uid $CREDENTIALS_DIRECTORY — the agent never opens the sops
  # paths and root never writes through the agent's tree).
  setupScript =
    name: inst:
    pkgs.writeShellScript "hermes-setup-${name}" ''
      set -eu
      hermesHome=${lib.escapeShellArg "${inst.stateDir}/.hermes"}

      # Merge Nix settings over the live config.yaml (Nix keys win, agent/runtime
      # keys survive).
      ${configMergeScript} ${generatedConfigFile name inst} "$hermesHome/config.yaml"
      chmod 0640 "$hermesHome/config.yaml"

      # Managed-mode marker: hermes refuses config-mutating CLI paths.
      : > "$hermesHome/.managed"
      chmod 0644 "$hermesHome/.managed"

      # Seed .env: declared non-secret env, then sops secrets from systemd creds.
      umask 0137
      {
      cat <<'HERMES_NIX_ENV_EOF'
      ${envFileContent inst}
      HERMES_NIX_ENV_EOF
      ${lib.concatStringsSep "\n" (
        lib.imap0 (i: _f: ''
          if [ -f "$CREDENTIALS_DIRECTORY/env${toString i}" ]; then
            printf '\n'
            cat "$CREDENTIALS_DIRECTORY/env${toString i}"
          fi
        '') inst.environmentFiles
      )}
      } > "$hermesHome/.env"
      chmod 0640 "$hermesHome/.env"
    '';

  # Shared unit scaffolding for gateway + dashboard: identity, env, hardening.
  baseUnit = name: inst: {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    environment = {
      HOME = inst.stateDir;
      HERMES_HOME = "${inst.stateDir}/.hermes";
      HERMES_MANAGED = "true";
      MESSAGING_CWD = inst.workingDirectory;
    };

    path = [
      inst.package
      pkgs.bash
      pkgs.coreutils
      pkgs.git
    ]
    ++ inst.extraPackages;

    serviceConfig = {
      User = name;
      Group = name;
      WorkingDirectory = inst.workingDirectory;
      UMask = "0007";

      # Upstream hardening set, plus what a headless agent tolerates. No
      # RestrictNamespaces / MemoryDenyWriteExecute: chromium's sandbox and
      # node's JIT need them.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [
        inst.stateDir
        inst.workingDirectory
      ];
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
    };
  };
in
{
  options.modules.apps.hermes-agents = {
    instances = lib.mkOption {
      type = lib.types.attrsOf instanceModule;
      default = { };
      description = "Hermes agent instances, one isolated zone each.";
    };
  };

  config = lib.mkIf (instances != { }) {
    users.groups = lib.mapAttrs (_name: _inst: { }) instances;
    users.users = lib.mapAttrs (name: inst: {
      isSystemUser = true;
      group = name;
      home = inst.stateDir;
      createHome = true;
      # Real shell: codex/hermes login flows and admin `sudo -u <agent>` need it.
      shell = pkgs.bashInteractive;
      # Per-user profile puts hermes + the zone's tools on login-shell PATH,
      # so bootstrap flows are just `sudo -u <name> -i hermes auth add
      # codex-oauth` (HOME is the stateDir, so ~/.hermes is the right store).
      packages = [ inst.package ] ++ inst.extraPackages;
    }) instances;

    systemd.tmpfiles.rules = lib.concatLists (
      lib.mapAttrsToList (name: inst: [
        "d ${inst.stateDir}                  0750 ${name} ${name} - -"
        "d ${inst.stateDir}/.hermes          0750 ${name} ${name} - -"
        "d ${inst.stateDir}/.hermes/cron     0750 ${name} ${name} - -"
        "d ${inst.stateDir}/.hermes/sessions 0750 ${name} ${name} - -"
        "d ${inst.stateDir}/.hermes/logs     0750 ${name} ${name} - -"
        "d ${inst.stateDir}/.hermes/memories 0750 ${name} ${name} - -"
        "d ${inst.stateDir}/.hermes/plugins  0750 ${name} ${name} - -"
        "d ${inst.workingDirectory}          0750 ${name} ${name} - -"
      ]) instances
    );

    systemd.services = lib.mkMerge (
      lib.mapAttrsToList (
        name: inst:
        {
          # Seed config.yaml/.managed/.env as the agent uid before the gateway
          # (and dashboard) start. Required-by + before makes them fail closed if
          # seeding fails, and re-runs on every gateway (re)start — matching the
          # old activation-script's "re-seed each activation" behaviour. Secrets
          # come in as systemd credentials, never root-written through the tree.
          "${name}-setup" = {
            description = "Hermes config/env seeding (${name})";
            after = [ "systemd-tmpfiles-setup.service" ];
            before = [
              "${serviceName name}.service"
            ]
            ++ lib.optional inst.dashboard.enable "${serviceName name}-dashboard.service";
            requiredBy = [
              "${serviceName name}.service"
            ]
            ++ lib.optional inst.dashboard.enable "${serviceName name}-dashboard.service";
            restartTriggers = [ (generatedConfigFile name inst) ];
            serviceConfig = {
              Type = "oneshot";
              User = name;
              Group = name;
              UMask = "0027";
              LoadCredential = lib.imap0 (i: f: "env${toString i}:${f}") inst.environmentFiles;
              ExecStart = setupScript name inst;
            };
          };

          "${serviceName name}" = lib.mkMerge [
            (baseUnit name inst)
            {
              description = "Hermes agent gateway (${name})";
              wantedBy = [ "multi-user.target" ];
              # Hermes reads config.yaml/.env at startup; the activation
              # script re-renders them, but nothing else ties the unit to
              # `settings` — without this trigger a settings-only change
              # would deploy silently without taking effect.
              restartTriggers = [ (generatedConfigFile name inst) ];
              serviceConfig = {
                ExecStart = lib.concatStringsSep " " (
                  [
                    "${inst.package}/bin/hermes"
                    "gateway"
                  ]
                  ++ inst.extraArgs
                );
                Restart = "always";
                RestartSec = 5;
              }
              // inst.serviceConfig;
            }
          ];
        }
        // lib.optionalAttrs inst.dashboard.enable {
          "${serviceName name}-dashboard" = lib.mkMerge [
            (baseUnit name inst)
            {
              description = "Hermes dashboard (${name})";
              wantedBy = [ "multi-user.target" ];
              # Config (incl. dashboard auth) is read at startup — same
              # settings-change restart trigger as the gateway.
              restartTriggers = [ (generatedConfigFile name inst) ];
              # Same HERMES_HOME as the gateway: sessions, skills, approvals.
              serviceConfig = {
                ExecStart = lib.concatStringsSep " " [
                  "${inst.package}/bin/hermes"
                  "dashboard"
                  "--host"
                  inst.dashboard.host
                  "--port"
                  (toString inst.dashboard.port)
                  "--no-open"
                ];
                Restart = "always";
                RestartSec = 5;
              };
            }
          ];
        }
      ) instances
    );

    environment.persistence."/persist".directories = lib.concatLists (
      lib.mapAttrsToList (
        name: inst:
        lib.optional inst.persist {
          directory = inst.stateDir;
          user = name;
          group = name;
          mode = "0750";
        }
      ) instances
    );
  };
}
