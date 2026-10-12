# agent-auth's daemons (agent-auth's docs/sandbox-design.md), both pinned to
# the same broker key:
#   - hostd, on every host: dials out to the broker on recusant, pairs once per
#     host. Where the agent VM runs it freezes the VM on lockdown; with
#     modules.agentAuth.hostCommands it runs approved commands. It
#     decides itself what runs, from this config, its own TOTP secrets
#     (`sudo agent-auth-hostd totp-enroll`, once per host) and its arm state.
#     With modules.agentAuth.desktopPrompts its helper in the user's session
#     shows approval prompts while the user is there (presence: hypridle's
#     hooks);
#   - sandboxd, inside the agent VM (modules.agentVm's guest): runs the VM's
#     agents (headless claude/codex per conversation), routes their a2a.
#
# Inert until both exist:
#   - the agent-auth flake input provides the modules;
#   - `brokerPublicKey` below is set: the broker's public signing key, from
#     `agent-auth admin broker-key` once BROKER_SIGNING_KEY is in recusant's
#     agent-auth/env secret. Pinned here, in an audited commit, so no network
#     path can substitute another broker.
# Then pair, once each (the code is entered at the prompt, never as an
# argument: it would land in shell history):
#   hostd:    `agent-auth admin daemon-pair <host>`, then on the host
#             `sudo agent-auth-hostd pair`
#   sandboxd: `agent-auth admin daemon-pair --role sandbox <host>`, then on the
#             host `avm pair`
{
  config,
  inputs,
  lib,
  options,
  pkgs,
  username,
  ...
}:
let
  brokerPublicKey = "ed25519:CAGm4HjX5-lT9w2JNi7U1yomf5i7u8Sge5G7o0eNWpY";
  brokerUrl = "https://agent-auth.recusant.rooty.dev";
  modules = inputs.agent-auth.nixosModules or { };
  pinned = brokerPublicKey != null;
  hostName = config.networking.hostName;
  hostd = config.services.agent-auth-hostd;
  # The pinned agent-auth may predate hostd's local policy (tiers, the VM's
  # unit, desktop prompts): those settings wait for the flake update.
  hostdPolicy = (options.services.agent-auth-hostd or { }) ? tiers;
  # As agent-auth's module: with a tier or a VM to freeze, hostd runs as root.
  hostdOwner =
    if hostdPolicy && (hostd.tiers.user.enable || hostd.tiers.root.enable || hostd.vm.unit != null) then
      "root"
    else
      "agent-auth-hostd";
  hypridle = config.modules.desktop.full.hyprland.hypridle;
  prompts = config.modules.agentAuth.desktopPrompts;
  commands = config.modules.agentAuth.hostCommands;
  # hostd's "not now" check (exit 0 = show no prompt): the focused window is
  # fullscreen (a game, a video, a presentation), or Hyprland can't be asked
  # (unknown counts as away). The user service's environment may not carry
  # Hyprland's instance: the newest one in the runtime dir is used then.
  busy = pkgs.writeShellScript "agent-auth-desktop-busy" ''
    if [ -z "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
      sock="$(ls -t "''${XDG_RUNTIME_DIR:-/run/user/$UID}"/hypr/*/.socket.sock 2>/dev/null | head -n1)"
      [ -n "$sock" ] || exit 0
      HYPRLAND_INSTANCE_SIGNATURE="$(basename "$(dirname "$sock")")"
      export HYPRLAND_INSTANCE_SIGNATURE
    fi
    win="$(${pkgs.coreutils}/bin/timeout 3 ${config.programs.hyprland.package}/bin/hyprctl activewindow -j 2>/dev/null)" || exit 0
    # 0 none, 1 maximized, 2 fullscreen (3 both); no window: {}.
    case "$(printf '%s' "$win" | ${pkgs.jq}/bin/jq -r '.fullscreen // 0' 2>/dev/null)" in
      0|1|false) exit 1 ;;
      *) exit 0 ;;
    esac
  '';
  # The dialog: sbx-prompt, the one every sandbox broker here uses (Deny has
  # the focus, plain text). It doesn't wrap, and a command can be long: the
  # fields are folded here, continuation lines indented so that none can pose
  # as a line of the dialog's own.
  sbxPrompt = import ../../../lib/broker/prompt.nix pkgs;
  promptDialog = pkgs.writeShellScript "agent-auth-desk-prompt" ''
    fold() { printf '%s' "$1" | ${pkgs.coreutils}/bin/fold -s -w 96 | ${pkgs.gnused}/bin/sed '2,$s/^/      /'; }
    exec ${sbxPrompt}/bin/sbx-prompt --timeout "$1" --no-session -- "$2" "$(fold "$3")" "$(fold "$4")"
  '';
  desktopOptions = options.services.agent-auth-hostd.desktop or { };

  # The deploy steps as hostd templates (capability `tpl.<name>`): one named
  # command per step, with checked parameters, in place of an `sh -c` line an
  # agent wrote. Mirrored, names and patterns, in recusant's
  # agent-auth-policy.yaml (platforms.hostexec.templates) so the broker shows
  # what a request expands to; what runs is this host's copy.
  checkout = commands.checkout;
  branchPattern = "[A-Za-z0-9][A-Za-z0-9._/-]*";
  revPattern = "[0-9a-f]{40}";
  deployPath = lib.makeBinPath [
    pkgs.git
    pkgs.git-crypt
    pkgs.openssh
    pkgs.coreutils
  ];
  # As the user: the checkout's branch to GitHub. No force, no refspec (the
  # pattern admits neither a leading "+" or "-" nor a ":").
  dotsPush = pkgs.writeShellScriptBin "nixos-dots-push" ''
    set -euo pipefail
    export PATH=${deployPath}:$PATH
    exec git -C ${lib.escapeShellArg checkout} push origin "refs/heads/$1"
  '';
  # As the user: the checkout fast-forwarded to exactly that commit of the
  # branch, fetched over https (the repo is public; a headless host has no
  # SSH key for GitHub).
  dotsPull = pkgs.writeShellScriptBin "nixos-dots-pull" ''
    set -euo pipefail
    export PATH=${deployPath}:$PATH
    cd ${lib.escapeShellArg checkout}
    git fetch ${lib.escapeShellArg commands.remote} "refs/heads/$1"
    got="$(git rev-parse FETCH_HEAD)"
    if [ "$got" != "$2" ]; then
      echo "nixos-dots-pull: $1 is at $got, not $2; nothing changed" >&2
      exit 1
    fi
    git merge --ff-only FETCH_HEAD
    git log --oneline -1
  '';
  # As root: this host rebuilt from the checkout, only at that commit with
  # nothing uncommitted in tracked files. The checkout is the user's, so git
  # is told it is safe and nix gets SUDO_UID, as under sudo; the GitHub copy
  # can't be built (its secrets.nix is git-crypt's ciphertext).
  dotsRebuild = pkgs.writeShellScriptBin "nixos-dots-rebuild" ''
    set -euo pipefail
    export PATH=${deployPath}:$PATH
    d=${lib.escapeShellArg checkout}
    g() { git -c safe.directory="$d" -C "$d" "$@"; }
    at="$(g rev-parse HEAD)"
    if [ "$at" != "$1" ]; then
      echo "nixos-dots-rebuild: the checkout is at $at, not $1; nothing built" >&2
      exit 1
    fi
    if [ -n "$(g status --porcelain --untracked-files=no)" ]; then
      echo "nixos-dots-rebuild: the checkout has uncommitted changes; nothing built" >&2
      g status --short --untracked-files=no >&2
      exit 1
    fi
    SUDO_UID="$(stat -c %u "$d")" exec nixos-rebuild switch --flake "$d#${hostName}"
  '';
in
{
  # Conditional on the input, never on config (imports can't depend on it).
  imports = lib.optional (modules ? hostd) modules.hostd;

  # What hostd runs on this host for agents (agent-auth's "hostexec"). Every
  # command is one a human approved at the broker; the host then decides for
  # itself, from these settings, its TOTP secrets (`sudo agent-auth-hostd
  # totp-enroll`) and whether the tier is armed. Nothing runs before the
  # enrolment, or while a tier is disarmed without a code for that command.
  options.modules.agentAuth.hostCommands = {
    user = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = config.modules.agentVm.enable;
        defaultText = lib.literalExpression "config.modules.agentVm.enable";
        description = "Commands as ${username}.";
      };
      shells = lib.mkEnableOption ''
        time-boxed shells as ${username} (an hour at most): each opened with
        a TOTP code, every command shown on Discord before it runs
      '';
    };
    checkout = lib.mkOption {
      type = lib.types.path;
      default = "/persist/home/${username}/Documents/nixos-dots";
      description = "This host's nixos-dots checkout: what the nixos-dots-* templates push, fast-forward and rebuild from.";
    };
    remote = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/otisdog8/nixos-dots.git";
      description = "Where nixos-dots-pull fetches from (https: no key needed).";
    };
    root = {
      enable = lib.mkEnableOption ''
        commands as root: always a human's decision at the broker (never a
        rule or the LLM), and armed here for at most an hour
      '';
      shells = lib.mkEnableOption ''
        time-boxed root shells (two hours at most), opened with a root TOTP
        code, every command shown on Discord before it runs. Root on this
        host for as long as one is open
      '';
    };
  };

  options.modules.agentAuth.desktopPrompts = {
    enable = lib.mkEnableOption ''
      agent-auth approval prompts on this host's desktop, next to Discord
      (needs hypridle: it reports whether the user is there). Shown only
      while the session is unlocked, was used in the last few minutes, the
      focused window isn't fullscreen and do-not-disturb
      (`agent-auth-hostctl dnd 2h`) is off; Deny is the default button.
      Which requests may be asked at a desk is the broker's policy
      (recusant's agent-auth-policy.yaml, `desktop:`)
    '';
    idleAfter = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "Seconds without input before the user counts as idle.";
    };
    maxIdle = lib.mkOption {
      type = lib.types.str;
      default = "2m";
      description = "How long after going idle prompts are still shown (the screen locks at 5 minutes anyway).";
    };
    approve = {
      user = lib.mkEnableOption ''
        Allow at this desk as this host's own approval of a command on this
        host as ${username}: the dialog shows what the host would run, and
        no arming or TOTP code is needed. Whatever runs as ${username} here
        can answer that dialog, and could run the command itself
      '';
      root = lib.mkEnableOption ''
        the same for root commands on this host, followed by
        ${username}'s password (polkit; its dialog shows the command too)
      '';
    };
    sound = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = "${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/message-new-instant.oga";
      defaultText = lib.literalExpression ''"''${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/message-new-instant.oga"'';
      description = "Played when a prompt, or a notification an agent asked for (notify_operator), arrives. null: silent.";
    };
  };

  config = lib.mkMerge [
    (lib.optionalAttrs (modules ? hostd && pinned) {
      services.agent-auth-hostd = {
        enable = lib.mkDefault true;
        inherit brokerUrl brokerPublicKey;
      };
      # The host's identity key (lose it and the host must pair again) and
      # its TOTP secrets. Owned by whoever the service runs as (agent-auth's
      # hostd module), as its tmpfiles rules and StateDirectory expect.
      environment.persistence."/persist".directories = [
        {
          directory = "/var/lib/agent-auth-hostd";
          user = hostdOwner;
          group = hostdOwner;
          mode = "0700";
        }
      ];
    })
    (lib.optionalAttrs (modules ? hostd && pinned && hostdPolicy) {
      services.agent-auth-hostd = {
        user = lib.mkDefault username;
        # Lockdown freezes the agent VM.
        vm.unit = lib.mkIf config.modules.agentVm.enable (lib.mkDefault "agent-vm.service");
        # modules.agentAuth.hostCommands; no autoCommands anywhere.
        tiers.user.enable = lib.mkDefault commands.user.enable;
        tiers.user.shell.enable = lib.mkDefault (commands.user.enable && commands.user.shells);
        tiers.root.enable = lib.mkDefault commands.root.enable;
        tiers.root.shell.enable = lib.mkDefault (commands.root.enable && commands.root.shells);
        tiers.root.shell.maxDuration = lib.mkDefault "2h";
        templates = {
          nixos-dots-push = {
            tier = "user";
            argv = [
              "nixos-dots-push"
              "{branch}"
            ];
            params.branch = branchPattern;
          };
          nixos-dots-pull = {
            tier = "user";
            argv = [
              "nixos-dots-pull"
              "{branch}"
              "{rev}"
            ];
            params = {
              branch = branchPattern;
              rev = revPattern;
            };
          };
          nixos-dots-rebuild = {
            tier = "root";
            argv = [
              "nixos-dots-rebuild"
              "{rev}"
            ];
            params.rev = revPattern;
          };
        };
        desktop = lib.mkIf (prompts.enable && hypridle.enable) (
          {
            enable = true;
            inherit (prompts) maxIdle;
          }
          // lib.optionalAttrs (desktopOptions ? busyCommand) {
            busyCommand = [ "${busy}" ];
          }
          # Approval at this host's own desk, sbx-prompt as the dialog, the
          # attention sound: once the agent-auth input has them.
          // lib.optionalAttrs (desktopOptions ? approve) {
            inherit (prompts) approve;
            promptCommand = [
              "${promptDialog}"
              "{timeout}"
              "{who}"
              "{what}"
              "{detail}"
            ];
            attentionCommand = lib.optionals (prompts.sound != null) [
              "${pkgs.pipewire}/bin/pw-play"
              "${prompts.sound}"
            ];
          }
        );
      };
      # The templates' commands, on hostd's job PATH
      # (/run/current-system/sw/bin).
      environment.systemPackages = [
        dotsPush
        dotsPull
        dotsRebuild
      ];
      # hypridle and the lock screen tell hostd whether the user is there
      # (Hyprland keeps no logind idle or lock hints).
      modules.desktop.full.hyprland.hypridle = lib.mkIf hostd.desktop.enable {
        presenceCommand = lib.mkDefault "/run/current-system/sw/bin/agent-auth-hostctl presence";
        presenceTimeout = lib.mkDefault prompts.idleAfter;
      };
    })
    (lib.optionalAttrs (modules ? sandboxd && pinned) {
      modules.agentVm.guestModules = [
        modules.sandboxd
        (
          { pkgs, ... }:
          {
            services.agent-auth-sandboxd = {
              enable = true;
              inherit brokerUrl brokerPublicKey hostName;
              # The plain packages, not the nixpak launchers (`claude` on the
              # host is a sandbox wrapper; the VM is the sandbox here).
              runtimes = {
                claude.package = pkgs.unstable-small.claude-code;
                codex.package = pkgs.unstable-small.codex;
              };
            };
          }
        )
      ];
    })
  ];
}
