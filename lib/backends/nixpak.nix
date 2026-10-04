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
    brokerSocketName = "sbx-broker/${appName}.sock";
    pulseSocketName = if brokerOn then "sbx-broker/${appName}.pulse" else null;
  };
  binName = appCfg.packageName;
  brokerOn = config.modules.sandbox.broker.enable;
  audioMode = import ../audio-mode.nix;
  wlSecure = import ./wayland-security-context.nix pkgs;
  username = builtins.head appCfg.defaultUsernames;

  # A group's shared container (nixpak-group.nix): this app's command runs in it
  # when launched inside the group's projects.
  groups = config.modules.sandbox.groups;
  group = lib.findFirst (g: lib.elem appName groups.${g}.apps) null (lib.attrNames groups);
  sharedGroup =
    if group != null && config.modules.sandbox.containerGroups ? ${group} then
      config.modules.sandbox.containerGroups.${group}
    else
      null;
  member = {
    inherit
      appName
      appCfg
      cfg
      storage
      ;
    bin = binName;
    package = cfg.package;
    gpuDevices = config.modules.sandbox.gpuDevices;
    fallback = "${perAppPackage}/bin/${binName}";
  };

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

  # The app's own sandbox (and, for Wayland apps, its security-context wrapper).
  perAppPackage =
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
in
{
  # The app's session-bus filter (--talk/--own/… args) and nixpak's .flatpak-info,
  # reused by the VM implementation's D-Bus proxy (lib/backends/vm.nix).
  inherit (inner) dbusArgs flatpakInfoFile appId;
  package =
    if sharedGroup == null then
      perAppPackage
    else
      pkgs.symlinkJoin {
        inherit (perAppPackage) name;
        paths = [ perAppPackage ];
        postBuild = ''
          rm "$out/bin/${binName}"
          ln -s ${
            sharedGroup.launcherFor {
              bin = binName;
              inherit (member) package fallback;
              projects = map (
                p: if lib.hasPrefix "/" p then p else "/home/${username}/${lib.removePrefix "~/" p}"
              ) groups.${group}.projects;
            }
          } "$out/bin/${binName}"
        '';
      };
  systemConfig = {
    # Every nixpak app publishes its member record; shared group containers are
    # built from them (modules/system/sandbox.nix).
    modules.sandbox.containerMembers.${appName} = member;
    systemd.tmpfiles.rules = storage.tmpfilesRules;
    environment.persistence = storage.homePersistence;
    assertions = storage.assertions;
    modules.sandbox.broker.sandboxes.${appName} = {
      label = "${appName} (container)";
      audio = audioMode appCfg.capabilities;
    };
    # nixpak runs in the user's session, where systemd can't attach the cgroup IP
    # filter the other backends use, so only "open" is enforceable here.
    warnings =
      lib.optional
        (
          appCfg.capabilities.network
          && !(lib.elem cfg.sandbox.network.mode [
            "default"
            "open"
          ])
        )
        "sandbox app '${appName}': network mode \"${cfg.sandbox.network.mode}\" isn't enforced by the nixpak backend (it runs in your session); use the systemd backend or the VM.";
    modules.sandbox.stashMigrations = lib.optional (storage.stashEntries != [ ]) {
      app = appName;
      bin = binName;
      user = builtins.head appCfg.defaultUsernames; # old-layout source (jrt)
      owner = builtins.head appCfg.defaultUsernames; # target ownership (jrt)
      entries = map (e: { inherit (e) tier path; }) storage.stashEntries;
    };
  };
}
