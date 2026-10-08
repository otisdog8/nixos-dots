# A persistent container sandbox shared by a group's nixpak apps
# (modules.sandbox.groups.<g>, container mode).
#
# One bwrap sandbox, built by importing every member's own nixpak module
# (nixpak-pkg.nix `appModule`: its storage, binds and capabilities), whose entry
# point is `sbx-exec agent` (lib/sbx-exec.py). It runs as the user service
# sbx-group-<g>, started by the first launch; each member's command then runs
# inside it through the agent, on the launcher's own terminal (fds passed over
# the socket).
#
# Where a command runs (launcherFor), as a group VM's launcher does (grantCwd):
# a member that takes $PWD (capabilities.cwd) runs in the caller's directory,
# which the shared sandbox has to have as the same folder: a declared project,
# a folder granted earlier, or, anywhere else in ~, the folder the launcher has
# the root attach helper (lib/broker/attach.py, op path) mount in now (no
# prompt: the user started it there). Started in ~ itself it runs in the
# sandbox's home. A folder outside ~ the sandbox doesn't have, or one it can't
# be given, runs the member's own per-app sandbox instead (which binds $PWD),
# saying so; never somewhere else than asked. Members without $PWD (the games)
# run in the sandbox's home. Inside the group's sandbox already (one agent
# running another) a member runs right there.
#
# Differences from the members' own sandboxes: no $PWD bind (the agent's start
# directory isn't the caller's; see above) and no ./-relative binds; one flatpak
# identity (sbx.group.<g>) and one broker socket (group-<g>) for the whole
# group; each member's app.environment is set on its own commands only, not
# sandbox-wide.
{
  lib,
  pkgs,
  inputs,
  name,
  # Container member records (lib/backends/nixpak.nix `member`).
  members,
  persistent,
  # modules.sandbox.broker.enable: without it there is no broker socket to
  # relay audio through or to bind, and members use the user's PulseAudio.
  brokerOn,
}:
let
  paths = import ../paths.nix { inherit lib; };
  sbxExec = import ../sbx-exec.nix pkgs;
  wlSecure = import ./wayland-security-context.nix pkgs;

  memberModule =
    m:
    (import ./nixpak-pkg.nix {
      inherit lib pkgs inputs;
      inherit (m) storage;
      appCfg = m.appCfg // {
        capabilities = m.appCfg.capabilities // {
          cwd = false;
        };
        # Per member, on its commands (launcherFor), not for the whole sandbox.
        environment = { };
      };
      cfg = m.cfg // {
        sandbox = m.cfg.sandbox // {
          extraBinds = lib.filter (p: !(paths.isPwdRelative p)) m.cfg.sandbox.extraBinds;
          extraBindsReadOnly = lib.filter (p: !(paths.isPwdRelative p)) m.cfg.sandbox.extraBindsReadOnly;
        };
      };
      inherit (m) gpuDevices;
      # The group's one broker socket for audio too (bound by every member's
      # module at the same place).
      pulseSocketName = if brokerOn then "sbx-broker/group-${name}.pulse" else null;
    }).appModule;

  first = lib.head members;
  mkNixPak =
    (import ./nixpak-pkg.nix {
      inherit lib pkgs inputs;
      inherit (first) appCfg cfg storage;
    }).mkNixPak;

  appId = "sbx.group.${name}";
  runDir = "sbx-group/${name}";
  agentBin = pkgs.writeShellScriptBin "sbx-group-agent" ''
    exec ${sbxExec}/bin/sbx-exec agent --listen "$XDG_RUNTIME_DIR/${runDir}/agent.sock" ${
      lib.optionalString (!persistent) "--idle-exit 60"
    }
  '';

  built = mkNixPak {
    config =
      { sloth, ... }:
      {
        imports = map memberModule members;
        app.package = agentBin;
        app.binPath = "bin/sbx-group-agent";
        flatpak.appId = lib.mkForce appId;
        bubblewrap.bind.rw = [
          # rw: the agent makes its socket here (replacing a stale one).
          (sloth.concat' sloth.runtimeDir "/${runDir}")
        ]
        ++ lib.optional brokerOn [
          (sloth.concat' sloth.runtimeDir "/sbx-broker/group-${name}.sock")
          "/run/sbx/broker.sock"
        ];
      };
  };
  usesWayland = built.config.bubblewrap.sockets.wayland;

  start = pkgs.writeShellScript "sbx-group-${name}" ''
    set -eu
    rt="''${XDG_RUNTIME_DIR:?}"
    ${pkgs.coreutils}/bin/mkdir -p -m 0700 "$rt/${runDir}"
    ${
      if usesWayland then
        ''
          if [ -n "''${WAYLAND_DISPLAY:-}" ] && [ -S "$rt/$WAYLAND_DISPLAY" ]; then
            exec ${wlSecure}/bin/wayland-security-context run \
              "$rt/sbx-group-${name}-wayland" ${lib.escapeShellArg appId} \
              -- ${built.config.env}/bin/sbx-group-agent
          fi
          export WAYLAND_DISPLAY=sandbox-group-${name}-no-display
        ''
      else
        ""
    }
    exec ${built.config.env}/bin/sbx-group-agent
  '';
in
{
  inherit appId;
  # Any member may ask for the camera (the attach helper binds it into the
  # shared sandbox).
  camera = lib.any (m: m.appCfg.capabilities.camera) members;
  # The broker's audio mode for the whole group (lib/audio-mode.nix).
  audio = import ../audio-mode.nix {
    audio = lib.any (m: m.appCfg.capabilities.audio) members;
    microphone = lib.any (m: m.appCfg.capabilities.microphone) members;
  };
  socket = "${runDir}/agent.sock";
  service = {
    description = "Sandbox group ${name} (shared container)";
    # The session's environment (display, bus) comes from the user manager.
    partOf = [ "graphical-session.target" ];
    serviceConfig = {
      # Holds every member's container lock while it runs, so none of their
      # VMs can start meanwhile, nor it while one runs (lib/impl-lock.nix).
      ExecStart =
        let
          implLock = import ../impl-lock.nix { inherit lib pkgs; };
          hold = implLock.hold {
            cls = "container";
            apps = map (m: m.appName) (
              lib.filter (
                m:
                implLock.wanted {
                  backend = "nixpak";
                  inherit (m.storage) entries;
                }
              ) members
            );
          };
        in
        "${lib.optionalString (hold != "") "${hold} "}${start}";
      Restart = "no";
      KillMode = "mixed";
    };
  };

  # A member's command (see the top of this file for where it runs), else its
  # own sandbox (`fallback`, the per-app wrapper). The group's projects (which
  # nixpak.nix passes) aren't needed here: the sandbox itself says whether it
  # has the folder (`sbx-exec probe`).
  launcherFor =
    {
      bin,
      package,
      fallback,
      environment ? { },
      ...
    }:
    let
      member = lib.findFirst (m: m.bin == bin) null members;
      takesCwd = member != null && member.appCfg.capabilities.cwd;
      cmd = "${
        lib.optionalString (environment != { }) "${pkgs.coreutils}/bin/env ${
          lib.escapeShellArgs (lib.mapAttrsToList (k: v: "${k}=${v}") environment)
        } "
      }${package}/bin/${bin}";
      systemctl = "${pkgs.systemd}/bin/systemctl --user";
      attachProg = (import ../broker/attach.nix pkgs).forSandbox "group-${name}";
    in
    pkgs.writeShellScript "sbx-group-${name}-${bin}" ''
      # Inside a sandbox already (an agent running another, agent-peers): there's
      # no systemd user manager, and the group's socket directory there is the
      # host's, so leave both alone. In the group's own sandbox the command is
      # right here; in another one, its own sandbox nests.
      if [ -e /.flatpak-info ]; then
        if ${pkgs.gnugrep}/bin/grep -qxF ${lib.escapeShellArg "name=${appId}"} /.flatpak-info; then
          exec ${cmd} "$@"
        fi
        exec ${fallback} "$@"
      fi
      sock="''${XDG_RUNTIME_DIR:?}/${runDir}/agent.sock"
      # Started on first use. A socket a stopped sandbox left behind is the
      # agent's to replace (sbx-exec probe waits for it to answer).
      ${systemctl} --quiet is-active sbx-group-${name}.service \
        || ${systemctl} start sbx-group-${name}.service \
        || true
      here="$(pwd -P)"
      where=(--home)
      probe=()
      ${lib.optionalString takesCwd ''
        home="$(cd "''${HOME:-/}" 2>/dev/null && pwd -P)"
        if [ "$here" != "$home" ]; then
          where=(--cwd "$here")
          probe=(--dir "$here")
          case "$here" in "$home"/*) probe+=(--grant ${attachProg}) ;; esac
        fi
      ''}
      ${sbxExec}/bin/sbx-exec probe --socket "$sock" --wait 10 "''${probe[@]}"
      case $? in
        0) ;;
        3)
          echo "${bin}: the ${name} group sandbox isn't answering (journalctl --user -u sbx-group-${name}); using ${bin}'s own sandbox" >&2
          exec ${fallback} "$@"
          ;;
        *)
          echo "${bin}: $here isn't shared with the ${name} group sandbox; using ${bin}'s own sandbox" >&2
          exec ${fallback} "$@"
          ;;
      esac
      exec ${sbxExec}/bin/sbx-exec run --socket "$sock" "''${where[@]}" -- ${cmd} "$@"
    '';
}
