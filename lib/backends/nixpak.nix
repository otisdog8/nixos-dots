# nixpak backend — in-session, rootless bwrap wrapper (today's behaviour), binds
# sourced from app.storage. Stash dirs are jrt-owned (stashOwner = "user"); the
# app runs as jrt in the session, so data isn't hidden from the host — nixpak's
# isolation is the sandbox boundary, not host-hiding.
{
  appName,
  appCfg,
  cfg,
  config,
  lib,
  pkgs,
  inputs,
  storage,
}:
let
  inner = import ./nixpak-pkg.nix {
    inherit
      appCfg
      cfg
      lib
      pkgs
      inputs
      storage
      ;
    stashAtHome = false;
    gpuDevices = config.modules.sandbox.gpuDevices;
  };
  binName = appCfg.packageName;
  wlSecure = import ./wayland-security-context.nix pkgs;

  # Wayland apps get a wp_security_context_v1 socket, never the raw one (see
  # wayland-security-context.py); nixpak binds "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY",
  # which the helper points at it. Without a compositor socket (TTY/ssh),
  # WAYLAND_DISPLAY names a nonexistent socket — unset, nixpak would bind wayland-0.
  launcher = pkgs.writeShellScript "${appName}-wayland-secure" ''
    __wd="''${WAYLAND_DISPLAY:-}"; __rt="''${XDG_RUNTIME_DIR:-}"
    case "$__wd" in /*) __up="$__wd" ;; *) __up="$__rt/$__wd" ;; esac
    if [ -z "$__wd" ] || [ -z "$__rt" ] || [ ! -S "$__up" ]; then
      WAYLAND_DISPLAY=sandbox-${appName}-no-display exec ${inner.package}/bin/${binName} "$@"
    fi
    exec ${wlSecure}/bin/wayland-security-context run \
      "$__rt/sandbox-${appName}-wayland-$$" ${lib.escapeShellArg inner.appId} \
      -- ${inner.package}/bin/${binName} "$@"
  '';
in
{
  package =
    if inner.usesWayland then
      pkgs.symlinkJoin {
        inherit (inner.package) name;
        paths = [ inner.package ];
        postBuild = ''
          rm "$out/bin/${binName}"
          ln -s ${launcher} "$out/bin/${binName}"
          # nixpak rewrites absolute Exec=/D-Bus service paths in share/ to its
          # inner script; point them at this wrapper so no entry point bypasses
          # the security-context socket.
          if [ -d "$out/share" ]; then
            { grep -RlF "${inner.script}/bin/" "$out/share" || true; } | while IFS= read -r f; do
              t="$(readlink -f "$f")"
              rm "$f"
              sed "s|${inner.script}/bin/|$out/bin/|g" "$t" > "$f"
            done
          fi
        '';
      }
    else
      inner.package;
  systemConfig = {
    systemd.tmpfiles.rules = storage.tmpfilesRules;
    environment.persistence = storage.homePersistence;
    assertions = storage.assertions;
    modules.sandbox.stashMigrations = lib.optional (storage.stashEntries != [ ]) {
      app = appName;
      bin = binName;
      user = builtins.head appCfg.defaultUsernames; # old-layout source (jrt)
      owner = builtins.head appCfg.defaultUsernames; # target ownership (jrt)
      entries = map (e: { inherit (e) tier path; }) storage.stashEntries;
    };
  };
}
