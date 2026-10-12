# Container vs VM: an app's two implementations (lib/variants.nix) work on the
# same persisted data (its stash, or its ~ entries), and the app's own
# single-instance locks (a browser's profile lock, Steam's) don't reach across
# the VM boundary. So while one implementation runs, the other refuses to start.
#
# Each running implementation holds, for every app it serves, a SHARED flock on
# its own file, and the other's must be free:
#
#   /run/sandbox-impl/<app>.container   every running container of the app
#   /run/sandbox-impl/<app>.vm          every running VM of it (per-project VMs
#                                       of one app run side by side)
#
# Starting, an implementation takes its own file shared, then checks the other's
# by taking it exclusive for a moment (each waits up to a second, so a check
# never trips over another check). Two starting at once may both refuse; both
# never run.
#
# The holder is the implementation's long-lived host-side owner, so a launch
# that joins a running instance of the same implementation (a second window, a
# launcher attaching to its VM) never conflicts:
#   - container: nixpak's launcher (the app's command, or its group's service),
#     which outlives the sandbox; the systemd backend's unit, as root just before
#     the privilege drop; the `none` backend's command itself (the `-host`
#     variant). The descriptor is inherited by what they exec.
#   - VM: the VMM unit, beside crosvm (`hold-for`), never anything in the guest.
# Launchers also `check` first, as the user, to say so in a notification: the
# units have no session to show one.
#
# The files are root's (tmpfiles, in a root-owned dir under /run: no path a user
# controls) and 0444: every side opens them read-only, which flock is fine with.
# No sandbox sees /run/sandbox-impl, and no VM sees host files. Accepted: any
# host process may take a lock, which can only keep an app from starting; and a
# container app can unlock the descriptor it inherited (nixpak passes it into
# bwrap), which only drops its own protection. A missing file (before the first
# activation that declares it) is skipped: the launch goes ahead.
#
# Not locked: apps without persisted data, and app.multiInstance ones (the AI
# agents: they run several sessions on one data dir already). (A `none`-backend
# app locks only its main command: its other programs, e.g. wine's, start
# without the check.)
{ lib, pkgs }:
let
  dir = "/run/sandbox-impl";
  flock = "${pkgs.util-linux}/bin/flock";

  prog = pkgs.writeShellScript "sbx-impl-lock" ''
    # sbx-impl-lock hold     [--notify] container|vm APP... -- COMMAND...
    # sbx-impl-lock hold-for [--notify] container|vm APP... -- PID
    # sbx-impl-lock check    [--notify] container|vm APP...
    set -u
    mode="$1"; shift
    notify=0
    if [ "''${1:-}" = --notify ]; then notify=1; shift; fi
    cls="$1"; shift
    case "$cls" in
      container) other=vm; where="its VM" ;;
      vm) other=container; where="its container" ;;
      *) echo "sbx-impl-lock: unknown implementation '$cls'" >&2; exit 2 ;;
    esac
    refuse() {
      msg="$1 is already running in $where — close it first"
      echo "$msg" >&2
      if [ "$notify" = 1 ]; then
        ${pkgs.libnotify}/bin/notify-send -a "$1" -u critical "$1 not started" "$msg" >/dev/null 2>&1 &
      fi
      exit 1
    }
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
      app="$1"; shift
      if [ "$mode" != check ] && { exec {own}<"${dir}/$app.$cls"; } 2>/dev/null; then
        # Only a check of the other implementation holds it exclusive, briefly.
        ${flock} -s -w 1 "$own" || refuse "$app"
      fi
      if { exec {peer}<"${dir}/$app.$other"; } 2>/dev/null; then
        ${flock} -x -w 1 "$peer" || refuse "$app"
        exec {peer}<&-
      fi
    done
    [ "''${1:-}" = -- ] && shift
    case "$mode" in
      hold) exec "$@" ;;
      hold-for)
        # Keep the locks while PID lives (it execs the VMM next), in a process
        # of its own: whatever PID becomes needn't keep the descriptors.
        pid="$1"
        { ${pkgs.util-linux}/bin/waitpid "$pid" || while kill -0 "$pid"; do ${pkgs.coreutils}/bin/sleep 1; done; } >/dev/null 2>&1 &
        ;;
    esac
    exit 0
  '';
in
{
  inherit dir prog;

  # Whether an app's implementations lock each other out: not without data,
  # nor for an app that keeps several sessions on one data dir itself
  # (app.multiInstance).
  # (`backend` is unused: every backend locks.)
  wanted =
    {
      backend,
      entries,
      multiInstance ? false,
    }:
    entries != [ ] && !multiInstance;

  # systemd.tmpfiles.settings fragment declaring one app's two lock files.
  tmpfiles =
    appName:
    let
      file = {
        f = {
          mode = "0444";
          user = "root";
          group = "root";
        };
      };
    in
    {
      ${dir}.d = {
        mode = "0755";
        user = "root";
        group = "root";
      };
      "${dir}/${appName}.container" = file;
      "${dir}/${appName}.vm" = file;
    };

  # A command prefix: take `cls`'s locks on `apps`, then exec the rest of the
  # line ("" for no apps).
  hold =
    {
      cls,
      apps,
      notify ? false,
    }:
    lib.optionalString (
      apps != [ ]
    ) "${prog} hold ${lib.optionalString notify "--notify "}${cls} ${lib.escapeShellArgs apps} --";

  # A command: fail (with the message, and a notification) while the other
  # implementation holds any of `apps` ("" for no apps).
  check =
    {
      cls,
      apps,
      notify ? true,
    }:
    lib.optionalString (
      apps != [ ]
    ) "${prog} check ${lib.optionalString notify "--notify "}${cls} ${lib.escapeShellArgs apps}";

  # A command: take `cls`'s locks on `apps` and keep them until `pid` exits.
  holdFor =
    {
      cls,
      apps,
      pid,
    }:
    lib.optionalString (apps != [ ]) "${prog} hold-for ${cls} ${lib.escapeShellArgs apps} -- ${pid}";
}
