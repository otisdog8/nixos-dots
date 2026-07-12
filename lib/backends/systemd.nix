# systemd-stash backend — the app's private data lives in a root-owned stash
# (/persist/sandbox/<app>, 0700 root: the per-app LOCK). A static per-app system
# service runs, as its single ExecStart (`+` = full privileges),
# `unshare --mount … runScript`, which:
#   1. gets a fresh private, non-propagating mount namespace (from unshare),
#   2. as root grafts each stash leaf onto its ~/path via `mount --bind` — root
#      traverses the 0700 lock; the graft stays private to this ns,
#   3. setpriv-drops to the app principal and execs the inner bwrap wrapper.
# One invocation: systemd applies namespacing per-Exec, so a mount in ExecStartPre
# would be gone by ExecStart.
#
# TWO isolation modes (sandbox.dedicatedUser):
#   - same-uid (default): drops to jrt. Hides the stash from OTHER SANDBOXED apps
#     (their pid/mount ns) but NOT from an unsandboxed jrt shell (/proc/<pid>/root
#     is same-uid → readable). Good for app-to-app lateral-movement.
#   - dedicated: drops to a per-app `app-<name>` uid. A uid mismatch DAC-denies jrt
#     both the leaf AND /proc/<pid>/root (+ ptrace of its memory) — this is what
#     stops a compromised (non-root) jrt from reaching the app. It also fixes a
#     dedicated-only injection vector: jrt must NOT feed the app a jrt-writable env
#     file (LD_PRELOAD → code exec as app-<name>), so dedicated uses a Nix-derived
#     env only. Cross-uid GUI access to jrt's session sockets is granted just-in-
#     time by the in-session launcher via ACLs.
#   (Neither stops a ROOT-level host escape — that's the microVM tier.)
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
  username = builtins.head appCfg.defaultUsernames;
  uid = toString config.users.users.${username}.uid;
  gid = toString config.users.groups.${config.users.users.${username}.group}.gid;
  binName = appCfg.packageName;
  unitName = "sandbox-${appName}";
  envFile = "/run/user/${uid}/sandbox/${appName}.env";
  jrtRuntime = "/run/user/${uid}";

  dedicated = cfg.sandbox.dedicatedUser; # systemd: stashOwner == "dedicated"
  appUser = if dedicated then "app-${appName}" else username;
  appHome = "/home/${appUser}";
  sharedHome = "/home/${username}";
  # Same-uid apps use jrt's runtime dir directly. A dedicated app can't write into
  # jrt's 0700 /run/user/<uid> (nixpak needs to create .flatpak/nixpak-bus/etc.),
  # so it gets its OWN runtime dir with jrt's session sockets bind-mounted in.
  runtimeDir = if dedicated then "/run/${appUser}" else jrtRuntime;

  co = "${pkgs.coreutils}/bin";
  ul = "${pkgs.util-linux}/bin";
  acl = "${pkgs.acl}/bin";

  stashEntries = lib.filter (e: e.location == "stash") storage.entries;

  innerPkg = import ./nixpak-pkg.nix {
    inherit
      appCfg
      cfg
      lib
      pkgs
      inputs
      storage
      ;
    stashAtHome = true;
    # dedicated: shared jrt data (extraBinds like the vault) lives in jrt's home,
    # not the app's own home.
    sharedHome = if dedicated then sharedHome else null;
  };

  # WAYLAND_DISPLAY is the only session var we can't state as a Nix literal, so it
  # is globbed at runtime (Nix-controlled, no jrt input). Done for dedicated and
  # for same-uid `defaults` mode; same-uid `inject` gets it from the env file.
  needsGlob = dedicated || cfg.sandbox.envMode == "defaults";

  runScript = pkgs.writeShellScript "sandbox-run-${appName}" ''
    set -eu
    ${lib.optionalString dedicated ''
      # App's own runtime dir; jrt's session sockets bound in (ns-private, so they
      # never appear on the host) and ACL'd by the launcher. nixpak's own writes
      # (.flatpak, nixpak-bus, wayland proxy) then land in a dir the app owns.
      ${co}/mkdir -p "${runtimeDir}"
      ${co}/chown "${appUser}" "${runtimeDir}" 2>/dev/null || true
      ${co}/chmod 700 "${runtimeDir}"
      for __s in ${jrtRuntime}/wayland-* ${jrtRuntime}/pipewire-* ${jrtRuntime}/pulse ${jrtRuntime}/bus; do
        [ -e "$__s" ] || continue
        __n="$(${co}/basename "$__s")"
        if [ -d "$__s" ]; then ${co}/mkdir -p "${runtimeDir}/$__n"; else ${co}/touch "${runtimeDir}/$__n"; fi
        ${ul}/mount --bind "$__s" "${runtimeDir}/$__n" 2>/dev/null || true
      done
    ''}
    ${lib.optionalString needsGlob ''
      __w=$(${co}/ls ${jrtRuntime}/wayland-* 2>/dev/null | ${co}/head -1 || true)
      if [ -n "''${__w:-}" ]; then export WAYLAND_DISPLAY="$(${co}/basename "$__w")"; fi
    ''}
    ${lib.concatMapStringsSep "\n" (e: ''
      ${co}/mkdir -p "${appHome}/${e.path}"
      ${ul}/mount --bind "${e.stashPath}" "${appHome}/${e.path}"
    '') stashEntries}
    ${
      if dedicated then
        ''
          __u=$(${co}/id -u ${appUser}); __g=$(${co}/id -g ${appUser})
          exec ${ul}/setpriv --reuid="$__u" --regid="$__g" --init-groups ${innerPkg}/bin/${binName}
        ''
      else
        ''
          exec ${ul}/setpriv --reuid=${uid} --regid=${gid} --init-groups ${innerPkg}/bin/${binName}
        ''
    }
  '';

  # Curated env forwarded from the session (same-uid inject mode only). Covers the
  # session vars features reference via `sloth.envOr`.
  injectVars = [
    "XDG_RUNTIME_DIR"
    "WAYLAND_DISPLAY"
    "DBUS_SESSION_BUS_ADDRESS"
    "DISPLAY"
    "LANG"
    "QT_QPA_PLATFORMTHEME"
  ];

  launcher = pkgs.writeShellScriptBin binName ''
    set -eu
    ${
      if dedicated then
        ''
          # Grant app-${appUser} rw on ONLY the specific session sockets (which the
          # runScript binds into the app's own runtime dir). No ACL on jrt's
          # runtime dir itself → app-${appUser} can't list/create/delete there.
          for __s in "${jrtRuntime}"/wayland-* "${jrtRuntime}"/pipewire-* "${jrtRuntime}/pulse" "${jrtRuntime}/bus"; do
            if [ -e "$__s" ]; then ${acl}/setfacl -R -m "u:${appUser}:rwX" "$__s" 2>/dev/null || true; fi
          done
          # Shared jrt data (vault etc.): traverse the path + rw the tree.
          ${lib.concatMapStringsSep "\n" (p: ''
            ${acl}/setfacl -m "u:${appUser}:x" "${sharedHome}" 2>/dev/null || true
            ${acl}/setfacl -m "u:${appUser}:x" "$(${co}/dirname "${sharedHome}/${p}")" 2>/dev/null || true
            ${acl}/setfacl -R -m "u:${appUser}:rwX" "${sharedHome}/${p}" 2>/dev/null || true
          '') (lib.filter (p: !(lib.hasPrefix "/" p) && !(lib.hasPrefix "." p)) cfg.sandbox.extraBinds)}
        ''
      else
        lib.optionalString (cfg.sandbox.envMode == "inject") ''
          umask 077
          ${co}/mkdir -p "$(${co}/dirname "${envFile}")"
          : > "${envFile}"
          for v in ${lib.concatStringsSep " " injectVars}; do
            val="$(${co}/printenv "$v" 2>/dev/null || true)"
            [ -n "$val" ] && ${co}/printf '%s=%s\n' "$v" "$val" >> "${envFile}"
          done
        ''
    }
    trap '${pkgs.systemd}/bin/systemctl stop ${unitName}.service >/dev/null 2>&1 || true' EXIT INT TERM
    ${pkgs.systemd}/bin/systemctl start --wait ${unitName}.service
  '';

  finalPkg = pkgs.runCommand "${appName}-stash" { } ''
    mkdir -p $out/bin
    ln -s ${launcher}/bin/${binName} "$out/bin/${binName}"
    if [ -d ${innerPkg}/share ]; then
      mkdir -p $out/share
      cp -r --no-preserve=mode ${innerPkg}/share/. $out/share/
      for f in $out/share/applications/*.desktop; do
        [ -e "$f" ] || continue
        ${pkgs.gnused}/bin/sed -i "s|Exec=[^[:space:]]*/${binName}|Exec=${binName}|g" "$f"
      done
    fi
  '';

  # ptrace_scope hardening baseline for the SAME-UID stash (blocks ATTACH memory
  # scraping). It does NOT hide the stash via /proc/<pid>/root — dedicated does.
  ptraceAssertion = lib.optional (cfg.sandbox.stashOwner == "root") {
    assertion = builtins.toString (config.boot.kernel.sysctl."kernel.yama.ptrace_scope" or 0) != "0";
    message = ''
      sandbox app '${appName}' uses the systemd same-uid stash. Set
      kernel.yama.ptrace_scope >= 1 (via modules.system.hardening) so a same-uid
      process can't PTRACE_ATTACH and scrape the running app's memory. NOTE: this
      does NOT hide the stash from an unsandboxed same-uid shell via
      /proc/<pid>/root — only sandbox.dedicatedUser does that.
    '';
  };
in
{
  package = finalPkg;
  systemConfig = {
    systemd.tmpfiles.rules = storage.tmpfilesRules; # dedicated → leaf owned app-<name>
    environment.persistence = storage.homePersistence;
    assertions = storage.assertions ++ ptraceAssertion;
    modules.sandbox.stashMigrations = lib.optional (storage.stashEntries != [ ]) {
      app = appName;
      bin = binName;
      user = username; # old-layout source is always under the human user's home
      owner = appUser; # target ownership: jrt (same-uid) or app-<name> (dedicated)
      entries = map (e: { inherit (e) tier path; }) storage.stashEntries;
    };

    users.groups = lib.optionalAttrs dedicated { "app-${appName}" = { }; };
    users.users = lib.optionalAttrs dedicated {
      "app-${appName}" = {
        isSystemUser = true;
        group = "app-${appName}";
        home = appHome;
        createHome = true;
      };
    };

    systemd.services.${unitName} = {
      description = "Sandboxed stash service: ${appName}";
      serviceConfig = {
        Type = "exec";
        # Root (+) so it can unshare a mount ns and graft the stash; runScript
        # drops to the app principal via setpriv before exec'ing the sandbox.
        ExecStart = "+${pkgs.util-linux}/bin/unshare --mount --propagation private -- ${runScript}";
        Restart = "no";
        Environment = [
          "HOME=${appHome}"
        ]
        ++ lib.optionals needsGlob [
          "XDG_RUNTIME_DIR=${runtimeDir}"
          "DBUS_SESSION_BUS_ADDRESS=unix:path=${runtimeDir}/bus"
        ]
        ++ lib.optionals dedicated [
          "LANG=${config.i18n.defaultLocale}"
        ];
      }
      # Only the same-uid inject mode reads a jrt-written env file; dedicated NEVER
      # does (that would be an LD_PRELOAD injection into a different-uid process).
      // lib.optionalAttrs (!dedicated && cfg.sandbox.envMode == "inject") {
        EnvironmentFile = "-${envFile}";
      };
    };
  };
}
