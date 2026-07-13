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
  bwrap = "${pkgs.bubblewrap}/bin/bwrap";
  # Patched proxy (drops the in-band AUTH EXTERNAL uid) — see the
  # xdg-dbus-proxy-crossuid overlay. Only the bridge uses it, so nixpak's own
  # proxy and every other xdg-dbus-proxy consumer stay on the stock build.
  dbusProxy = "${pkgs.xdg-dbus-proxy-crossuid}/bin/xdg-dbus-proxy";
  # jrt-side D-Bus bridge socket (dedicated only). D-Bus rejects the app's uid at
  # EXTERNAL auth, so a transparent xdg-dbus-proxy run AS JRT authenticates to the
  # session bus and relays; the app reaches it through the runScript's bind.
  #
  # SECURITY (finding #3): the bridge is TRANSPARENT (unfiltered) — nixpak's own
  # inner proxy is the policy filter (--talk/--own). The raw bridge socket is
  # visible in the sandbox (/run/<app>/bus via the /run bind), so a compromised app
  # could connect to it directly and get unfiltered jrt-session-bus authority,
  # bypassing nixpak's filter. This is NOT a regression: a same-uid nixpak app can
  # already reach jrt's real bus (/run/user/<uid>/bus) directly and bypass the same
  # filter — the dedicated app has strictly LESS (its own data is uid-hidden, and it
  # can't reach the raw bus, only the bridge). Making the bridge --filter'ed is the
  # defense-in-depth follow-up, but it must replicate the app's exact policies AND
  # the portal Request/Response object tracking through two chained proxies (which
  # currently makes screenshare work) — so it's deferred, not free.
  bridgeSock = "${jrtRuntime}/sandbox-${appName}-bus";

  stashEntries = lib.filter (e: e.location == "stash") storage.entries;

  innerNix = import ./nixpak-pkg.nix {
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
    # dedicated: expose the relayed doc FUSE at jrt's identity path inside the
    # sandbox (the portal returns jrt-absolute doc:// paths). Same-uid apps use
    # nixpak's own mountDocumentPortal (same uid, no relay needed).
    docBind = if dedicated then [ "${runtimeDir}/doc" "${jrtRuntime}/doc" ] else null;
  };
  innerPkg = innerNix.package;
  # nixpak's .flatpak-info for this app — bound onto the bridge below (dedicated).
  # The portal's flatpak app-info parser REQUIRES an [Instance] group, but nixpak's
  # writeINI infoFile only emits [Application]/[Context]/[Session Bus Policy]. Append
  # an [Instance] group (matching nixpak's own flatpak-shim: flatpak.nix) so the
  # portal accepts the identity instead of failing with "does not have group Instance".
  # instance-id is per-app (dedicated apps share jrt's runtime, so a fixed id would
  # collide): the portal reads .flatpak/<instance-id>/bwrapinfo.json under it.
  flatpakInfoFile = pkgs.runCommand "sandbox-${appName}-flatpak-info" { } ''
    cat ${innerNix.flatpakInfoFile} > "$out"
    printf '\n[Instance]\ninstance-id=${appName}\nsession-bus-proxy=true\nsystem-bus-proxy=true\n' >> "$out"
  '';

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
      # Recreate it FRESH each launch (its parent /run is root-owned, so the app
      # can't swap the dir for a symlink) — this clears any stale symlinks/mount
      # targets the previous, possibly-compromised, app uid left as a trap.
      ${co}/rm -rf "${runtimeDir}"
      ${co}/mkdir -p "${runtimeDir}"
      ${co}/chown "${appUser}" "${runtimeDir}" 2>/dev/null || true
      ${co}/chmod 700 "${runtimeDir}"
      for __s in ${jrtRuntime}/wayland-* ${jrtRuntime}/pipewire-* ${jrtRuntime}/pulse; do
        [ -e "$__s" ] || continue
        __n="$(${co}/basename "$__s")"
        if [ -d "$__s" ]; then ${co}/mkdir -p "${runtimeDir}/$__n"; else ${co}/touch "${runtimeDir}/$__n"; fi
        ${ul}/mount --bind "$__s" "${runtimeDir}/$__n" 2>/dev/null || true
      done
      # Cross-uid document portal: jrt's doc FUSE lives under jrt's 0700 runtime dir
      # (the app can't traverse there), so root relays it into the app's own runtime
      # dir. The FUSE is mounted allow_other (xdg-desktop-portal fork), so the app
      # uid can then read the doc:// files the portal exports. nixpak binds this at
      # jrt's identity path inside the sandbox (docBind), where returned paths land.
      if [ -d "${jrtRuntime}/doc" ]; then
        ${co}/mkdir -p "${runtimeDir}/doc"
        ${ul}/mount --bind "${jrtRuntime}/doc" "${runtimeDir}/doc" 2>/dev/null || true
      fi
      # D-Bus session bus goes through the jrt-side bridge (started by the launcher),
      # NOT the raw bus — the app's uid is rejected at D-Bus EXTERNAL auth.
      if [ -S "${bridgeSock}" ]; then
        ${co}/touch "${runtimeDir}/bus"
        ${ul}/mount --bind "${bridgeSock}" "${runtimeDir}/bus" 2>/dev/null || true
      fi
    ''}
    ${lib.optionalString needsGlob ''
      __w=$(${co}/ls ${jrtRuntime}/wayland-* 2>/dev/null | ${co}/head -1 || true)
      if [ -n "''${__w:-}" ]; then export WAYLAND_DISPLAY="$(${co}/basename "$__w")"; fi
    ''}
    ${lib.concatMapStringsSep "\n" (e: ''
      __t="${appHome}/${e.path}"
      ${co}/mkdir -p "$__t"
      # Root-stage safety: refuse to graft through a symlink the app may have
      # planted anywhere in the target path (realpath != literal ⇒ a component
      # resolved elsewhere). Fail closed rather than bind over an app-chosen path.
      if [ "$(${co}/realpath "$__t")" != "$__t" ]; then
        echo "sandbox-${appName}: graft target '$__t' resolved through a symlink; refusing" >&2
        exit 1
      fi
      ${ul}/mount --bind "${e.stashPath}" "$__t"
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
    __dbus_pid=""
    ${
      if dedicated then
        ''
          # Grant app-${appUser} rw on ONLY the specific session sockets (which the
          # runScript binds into the app's own runtime dir). No ACL on jrt's
          # runtime dir itself → app-${appUser} can't list/create/delete there.
          for __s in "${jrtRuntime}"/wayland-* "${jrtRuntime}"/pipewire-* "${jrtRuntime}/pulse"; do
            if [ -e "$__s" ]; then ${acl}/setfacl -R -m "u:${appUser}:rwX" "$__s" 2>/dev/null || true; fi
          done
          # Cross-uid D-Bus bridge: a transparent xdg-dbus-proxy run AS JRT (so it
          # authenticates to the session bus fine), exposing an ACL'd socket the
          # runScript binds in as the app's bus. Unblocks tray + portals + notifs.
          #
          # Wrapped in a minimal bwrap whose ONLY purpose is to give the bridge a
          # /.flatpak-info at its /proc/root: the portal resolves a caller's identity
          # from /proc/<peer-pid>/root/.flatpak-info, and the peer it sees is THIS
          # bridge — so this makes it identify the dedicated app by its real app-id
          # and hand out doc:// paths (vs "host" + real paths). Same bwrap recipe as
          # nixpak's own dbus-proxy wrapper: default (writable tmpfs) root so the
          # /.flatpak-info mountpoint can be created, selective binds, and NO
          # --unshare-user/--uid — bwrap's default preserves the real uid (${uid}),
          # so the crossuid SO_PEERCRED/AUTH-EXTERNAL match is unchanged. Reuses
          # nixpak's generated infoFile — no policy duplication.
          ${co}/rm -f "${bridgeSock}" 2>/dev/null || true
          ${bwrap} \
            --ro-bind-try /etc /etc \
            --ro-bind /nix/store /nix/store \
            --bind-try /var /var \
            --bind-try /tmp /tmp \
            --bind /run /run \
            --ro-bind-try "${flatpakInfoFile}" /.flatpak-info \
            --die-with-parent \
            -- ${dbusProxy} "$DBUS_SESSION_BUS_ADDRESS" "${bridgeSock}" &
          __dbus_pid=$!
          for __i in $(${co}/seq 1 60); do [ -S "${bridgeSock}" ] && break; ${co}/sleep 0.05; done
          ${acl}/setfacl -m "u:${appUser}:rw" "${bridgeSock}" 2>/dev/null || true
          # The portal (running as jrt) resolves the flatpak instance named in the
          # bridge's .flatpak-info by reading jrt's own runtime dir:
          # $XDG_RUNTIME_DIR/.flatpak/<instance-id>/bwrapinfo.json. nixpak writes that
          # into the APP's runtime dir (invisible to the jrt portal), so mirror a
          # placeholder here (child-pid 1, exactly as nixpak's flatpak-shim does).
          ${co}/mkdir -p "${jrtRuntime}/.flatpak/${appName}"
          ${co}/printf '{"child-pid": 1, "mnt-namespace": 1, "net-namespace": 1, "pid-namespace": 1}' \
            > "${jrtRuntime}/.flatpak/${appName}/bwrapinfo.json"
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
    trap 'if [ -n "$__dbus_pid" ]; then kill "$__dbus_pid" 2>/dev/null || true; fi; ${pkgs.systemd}/bin/systemctl stop ${unitName}.service >/dev/null 2>&1 || true' EXIT INT TERM
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
        # No core dumps: a sandboxed app's core would write its memory — including
        # secrets like the Discord token this stash exists to hide — in plaintext
        # to /var/lib/systemd/coredump. (Also silences electron's spurious
        # speech-dispatcher thread-abort dumps.)
        LimitCORE = 0;
        Environment = [
          "HOME=${appHome}"
          # setpriv --reuid/--regid does NOT reset USER/LOGNAME, so without these
          # the app runs as the target uid but still sees USER=root (the service
          # starts as root before the drop) while HOME points at the app's home —
          # an inconsistency that breaks path construction and "am I root" checks.
          "USER=${appUser}"
          "LOGNAME=${appUser}"
          # Point libpulse straight at the bound pulse socket. Otherwise it tries
          # to set up $XDG_RUNTIME_DIR/pulse as a "secure directory" it must OWN —
          # which fails under the dedicated uid (the dir is bound from jrt, wrong
          # owner) and under same-uid (the dir comes back mounted read-only) — and
          # Electron then falls back to raw ALSA (no card = no audio). Connecting
          # directly to the socket skips the runtime-dir setup entirely.
          "PULSE_SERVER=unix:${runtimeDir}/pulse/native"
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
