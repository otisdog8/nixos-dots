# A persistent container sandbox shared by a group's nixpak apps
# (modules.sandbox.groups.<g>, container mode).
#
# One bwrap sandbox, built by importing every member's own nixpak module
# (nixpak-pkg.nix `appModule`: its storage, binds and capabilities), whose entry
# point is `sbx-exec agent` (lib/sbx-exec.py). It runs as the user service
# sbx-group-<g>, started by the first launch; each member's command then runs
# inside it through the agent, on the launcher's own terminal (fds passed over
# the socket). A group with projects shares only launches started inside one of
# them (the others run the member's ordinary per-app sandbox: the shared one
# doesn't see that directory); a group without projects shares every launch.
#
# Differences from the members' own sandboxes: no $PWD bind (the agent's start
# directory isn't the caller's) and no ./-relative binds; one flatpak identity
# (sbx.group.<g>) and one broker socket (group-<g>) for the whole group; each
# member's app.environment is set on its own commands only, not sandbox-wide.
{
  lib,
  pkgs,
  inputs,
  name,
  # Container member records (lib/backends/nixpak.nix `member`).
  members,
  persistent,
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
        };
      };
      inherit (m) gpuDevices;
      # The group's one broker socket for audio too (bound by every member's
      # module at the same place).
      pulseSocketName = "sbx-broker/group-${name}.pulse";
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
          (sloth.concat' sloth.runtimeDir "/${runDir}")
          [
            (sloth.concat' sloth.runtimeDir "/sbx-broker/group-${name}.sock")
            "/run/sbx/broker.sock"
          ]
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
      ExecStart = start;
      Restart = "no";
      KillMode = "mixed";
    };
  };

  # A member's command: into the group's sandbox when the group has no projects
  # or it's started inside one of them, else its own sandbox (`fallback`, the
  # per-app wrapper).
  launcherFor =
    {
      bin,
      package,
      fallback,
      projects,
      environment ? { },
    }:
    pkgs.writeShellScript "sbx-group-${name}-${bin}" ''
      here="$(pwd -P)"
      shared=${if projects == [ ] then "1" else "0"}
      for p in ${lib.escapeShellArgs projects}; do
        case "$here/" in "$p"/*) shared=1 ;; esac
      done
      [ "$shared" = 1 ] || exec ${fallback} "$@"
      sock="''${XDG_RUNTIME_DIR:?}/${runDir}/agent.sock"
      if ! ${pkgs.systemd}/bin/systemctl --user --quiet is-active sbx-group-${name}.service; then
        # A socket left by a stopped sandbox would answer nothing.
        ${pkgs.coreutils}/bin/rm -f "$sock"
        ${pkgs.systemd}/bin/systemctl --user start sbx-group-${name}.service
        for _ in $(${pkgs.coreutils}/bin/seq 1 100); do
          [ -S "$sock" ] && break
          ${pkgs.coreutils}/bin/sleep 0.1
        done
      fi
      if [ ! -S "$sock" ]; then
        echo "${bin}: the ${name} group sandbox didn't start (journalctl --user -u sbx-group-${name}); using ${bin}'s own sandbox" >&2
        exec ${fallback} "$@"
      fi
      exec ${sbxExec}/bin/sbx-exec run --socket "$sock" --cwd "$here" -- ${
        lib.optionalString (environment != { }) "${pkgs.coreutils}/bin/env ${
          lib.escapeShellArgs (lib.mapAttrsToList (k: v: "${k}=${v}") environment)
        } "
      }${package}/bin/${bin} "$@"
    '';
}
