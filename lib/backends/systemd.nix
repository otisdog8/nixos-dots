# systemd-stash backend — the app's private data lives in a root-owned stash
# (/persist/sandbox/<app>, 0700 root: the per-app LOCK). A static per-app system
# service runs, as its single ExecStart (as root, but confined: see `confinement`),
# `unshare --mount … runScript`, which:
#   1. gets a fresh private, non-propagating mount namespace (from unshare),
#   2. as root grafts each stash leaf onto its ~/path via `mount --bind` — root
#      traverses the 0700 lock; the graft stays private to this ns,
#   3. setpriv-drops to the app principal and execs the inner bwrap wrapper.
# One invocation: systemd applies namespacing per-Exec, so a mount in ExecStartPre
# would be gone by ExecStart.
#
# Root works only in root-owned directories nobody else can write (/run/app-<name>
# while it prepares it, the stash's root-owned parents); everything inside a
# directory another uid owns (jrt's runtime dir, the app's home) is done as that
# uid: mount-helper.py's owner-dropped children, or setpriv.
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
#     time by the in-session launcher via ACLs. With sandbox.appearAsUser (the
#     default) the app SEES itself as jrt (uid/gid, ~, runtime dir path; see
#     `identity` below), as in its VM; the host still runs it as app-<name>.
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
  jrtRuntime = "/run/user/${uid}";

  dedicated = cfg.sandbox.dedicatedUser; # dedicated app-<name> uid vs same-uid jrt
  appUser = if dedicated then "app-${appName}" else username;
  appHome = "/home/${appUser}";
  sharedHome = "/home/${username}";
  # Same-uid apps use jrt's runtime dir directly. A dedicated app can't write into
  # jrt's 0700 /run/user/<uid> (nixpak needs to create .flatpak/nixpak-bus/etc.),
  # so it gets its OWN runtime dir with jrt's session sockets bind-mounted in:
  # the unit's RuntimeDirectory (systemd makes it root-owned at start and
  # removes it at stop), handed to the app just before the privilege drop.
  runtimeDir = if dedicated then "/run/${appUser}" else jrtRuntime;
  # sandbox.appearAsUser: the dedicated app sees itself as the user. The
  # runScript mounts the app's home over the user's home path and its runtime
  # dir over the user's, in its own mount namespace, after staging the user's
  # real home (the source of the shared binds) at stageHome; bwrap maps the
  # app's uid/gid to the user's. The host still runs it as app-<name>, and every
  # permission check is still against that uid. (A VM shows the app the same
  # identity: lib/vm/guest.nix.)
  identity = dedicated && cfg.sandbox.appearAsUser;
  # Folder grants (sandboxes that run as the user) and the camera while it
  # runs (lib/broker/attach.py).
  attachProg = (import ../broker/attach.nix pkgs).forSandbox appName;
  camera = appCfg.capabilities.camera;
  brokerOn = config.modules.sandbox.broker.enable;
  sbxRequest = pkgs.writeScriptBin "sbx-request" (
    "#!${pkgs.python3}/bin/python3 -IS\n" + builtins.readFile ../broker/request.py
  );
  stageHome = "/run/sandbox-user-home/${appName}";

  co = "${pkgs.coreutils}/bin";
  fu = "${pkgs.findutils}/bin";
  ul = "${pkgs.util-linux}/bin";
  acl = "${pkgs.acl}/bin";
  bwrap = "${pkgs.bubblewrap}/bin/bwrap";
  busctl = "${pkgs.systemd}/bin/busctl";
  xhost = "${pkgs.xhost}/bin/xhost";
  grep = "${pkgs.gnugrep}/bin/grep";
  awk = "${pkgs.gawk}/bin/awk";
  # Patched proxy (drops the in-band AUTH EXTERNAL uid) — see the
  # xdg-dbus-proxy-crossuid overlay. Only the bridge uses it, so nixpak's own
  # proxy and every other xdg-dbus-proxy consumer stay on the stock build.
  dbusProxy = "${pkgs.xdg-dbus-proxy-crossuid}/bin/xdg-dbus-proxy";
  # jrt-side D-Bus bridge socket (dedicated only). D-Bus rejects the app's uid at
  # EXTERNAL auth, so a transparent xdg-dbus-proxy run AS JRT authenticates to the
  # session bus and relays; the app reaches it through the runScript's bind.
  #
  # SECURITY (finding #3): the FILTER lives HERE, on the jrt-side bridge (a trusted
  # uid the app can't tamper with), not on nixpak's inner proxy. nixpak-pkg.nix runs
  # the inner proxy TRANSPARENT for dedicated apps (transparentDbus → dbus.filter =
  # false) and the bridge applies the app's exact policies via bridgeFilterArgs +
  # --filter. This avoids the earlier chained-filter break (two xdg-dbus-proxy
  # --filter instances desynced reply/Request tracking → "Did not receive a reply"):
  # now there's ONE filter, and its client is a faithful transparent relay.
  bridgeSock = "${jrtRuntime}/sandbox-${appName}-bus";

  stashEntries = lib.filter (e: e.location == "stash") storage.entries;

  # Race-free root bind helper (see mount-helper.py) for every root bind through a
  # directory an unprivileged principal controls: jrt's runtime dir (relay
  # sources) and the app's home (graft targets). `-IS` is essential: it runs as
  # ROOT with HOME=/home/app-<name>, and plain python3 would honour PYTHON* env
  # vars and execute *.pth files from that app-writable home's user site dir.
  # (A shebang takes one argument, hence the combined flags.)
  mountHelper = pkgs.writeScript "sandbox-mount-helper" (
    "#!${pkgs.python3}/bin/python3 -IS\n" + builtins.readFile ./mount-helper.py
  );
  # A command prefix: the rest of the line runs as jrt (no supplementary groups).
  # The root phase's own looks into jrt's runtime dir go through it — root doesn't
  # resolve paths in a directory jrt owns (and, confined, has no CAP_DAC_* to).
  asUser = "${ul}/setpriv --reuid=${uid} --regid=${gid} --clear-groups --";
  # Cheap pre-filters (as jrt, through asUser) for the runScript's optional
  # relays; mount-helper.py does the authoritative, race-free check.
  pulseProbe = pkgs.writeShellScript "sandbox-pulse-probe-${appName}" ''
    __d=$(${co}/dirname "$1")
    [ -d "$__d" ] && [ ! -L "$__d" ] || exit 1
    # Session start can race the socket unit: give native a moment to appear.
    for __i in $(${co}/seq 1 40); do [ -e "$1" ] && break; ${co}/sleep 0.05; done
    [ -S "$1" ] && [ ! -L "$1" ]
  '';
  docProbe = pkgs.writeShellScript "sandbox-doc-probe-${appName}" ''
    [ -d "${jrtRuntime}/doc" ] \
      && [ ! -L "${jrtRuntime}/doc" ] \
      && [ ! -L "${jrtRuntime}/doc/by-app" ] \
      && [ ! -L "${jrtRuntime}/doc/by-app/${appId}" ]
  '';

  paths = import ../paths.nix { inherit lib; };

  # The app's display: a wp_security_context_v1 socket the launcher creates and
  # holds, never the raw compositor socket (see wayland-security-context.py).
  wlSecure = import ./wayland-security-context.nix pkgs;
  wlSock = "${jrtRuntime}/sandbox-${appName}-wayland";
  # extraBinds that are HOME-RELATIVE (not absolute, not ./ or ../): the subset the
  # launcher ACL-GRANTS under jrt's home and revokeAclsScript later tears back down.
  # One binding, referenced by both the grant block and the revoke script, so the
  # filter rule can never desync between grant and revoke (a mismatch would leave
  # ACLs granted that are never revoked — a standing-access leak).
  relExtraBinds = lib.filter (
    p: !(paths.isAbsolute p) && !(paths.isPwdRelative p)
  ) cfg.sandbox.extraBinds;
  # Every directory ABOVE a home-relative extraBind, from jrt's home down (e.g.
  # "a/b/c" → ~, ~/a, ~/a/b): each needs the app uid's traverse (x) bit, or bwrap
  # (running as that uid) silently skips the --bind-try.
  ancestorsOf =
    p:
    let
      comps = paths.components p;
    in
    map (n: lib.concatStringsSep "/" ([ sharedHome ] ++ lib.take n comps)) (
      lib.range 0 (lib.length comps - 1)
    );
  # sharedDownloads needs traverse on ~ and ~/Downloads too. Listed here so the
  # revoke script removes them along with the extraBinds ancestors.
  downloadsAncestors = lib.optionals (dedicated && cfg.sandbox.sharedDownloads) [
    sharedHome
    "${sharedHome}/Downloads"
  ];
  sharedAncestors = lib.unique (lib.concatMap ancestorsOf relExtraBinds ++ downloadsAncestors);

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
    gpuDevices = config.modules.sandbox.gpuDevices;
    # The broker socket: same-uid apps reach it in jrt's runtime dir; a dedicated
    # app's is relayed into its own runtime dir by the runScript below.
    brokerSocketName = if dedicated then "sbx-broker.sock" else "sbx-broker/${appName}.sock";
    # Audio: the broker's filtered pulse socket, never jrt's raw pulse dir (which
    # records everything). Same-uid apps bind it from jrt's runtime dir, as
    # nixpak.nix does (without the broker, jrt's own pulse, as there too); a
    # dedicated app's own runtime dir already has it at pulse/native (runScript).
    pulseSocketName = if !dedicated && brokerOn then "sbx-broker/${appName}.pulse" else null;
    # dedicated: shared jrt data (extraBinds like the vault) lives in jrt's home,
    # not the app's own home (with appearAsUser: at its stage, since the app's
    # home is mounted over jrt's).
    sharedHome =
      if identity then
        stageHome
      else if dedicated then
        sharedHome
      else
        null;
    identity =
      if identity then
        {
          uid = config.users.users.${username}.uid;
          gid = config.users.groups.${config.users.users.${username}.group}.gid;
          home = sharedHome;
          oldHome = appHome;
        }
      else
        null;
    # dedicated: expose the relayed doc FUSE at jrt's identity path inside the
    # sandbox (the portal returns jrt-absolute doc:// paths). Same-uid apps use
    # nixpak's own mountDocumentPortal (same uid, no relay needed).
    docBind =
      if dedicated then
        [
          "${runtimeDir}/doc"
          "${jrtRuntime}/doc"
        ]
      else
        null;
    # dedicated: inner proxy transparent; the jrt-side bridge is the single filter.
    transparentDbus = dedicated;
    # Expose jrt's X socket + DISPLAY to the inner sandbox (the xhost grant that makes
    # it usable is in the launcher). See nixos/modules/apps/xwayland-forward.md.
    x11Forward = dedicated && cfg.sandbox.x11Forward;
    # Per-app shared downloads → jrt's ~/Downloads/<app>. Value is the subdir name.
    sharedDownloads = if dedicated && cfg.sandbox.sharedDownloads then appName else null;
  };
  innerPkg = innerNix.package;
  usesWayland = innerNix.usesWayland;
  # Bridge filter: the app's own dbus policies (--talk/--own/...) + --filter, applied
  # to the jrt-side bridge. Only meaningful for dedicated (inner is transparent then).
  bridgeFilterArgs = lib.concatMapStringsSep " " lib.escapeShellArg (
    innerNix.dbusArgs ++ [ "--filter" ]
  );
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
  # Flatpak app-id — scopes the cross-uid doc bind to this app's by-app/<appId>.
  appId = innerNix.appId;

  # The compositor's socket name (Hyprland: wayland-1). Pinned, never globbed, so a
  # jrt-planted lexically-earlier socket can't win. Dedicated apps see their
  # relayed security-context socket under this name, and the launcher falls back
  # to it as the upstream socket when started without WAYLAND_DISPLAY.
  # needsWaylandDisplay: dedicated and same-uid "defaults" mode (same-uid
  # "inject" is refused: injectAssertion).
  needsWaylandDisplay = dedicated || cfg.sandbox.envMode == "defaults";
  waylandSocket = "wayland-1";

  # While the sandbox runs, the app's VM can't start, and the other way round
  # (lib/impl-lock.nix). Taken by the unit as root, just before the privilege
  # drop (the lock file sits in a root-owned dir), and inherited by the sandbox.
  # The unit runs one instance, so later launches never take it.
  implLock = import ../impl-lock.nix { inherit lib pkgs; };
  lockApps = lib.optional (implLock.wanted {
    backend = "systemd";
    inherit (storage) entries;
  }) appName;
  lockHold = implLock.hold {
    cls = "container";
    apps = lockApps;
  };
  lockCheck = implLock.check {
    cls = "container";
    apps = lockApps;
  };

  runScript = pkgs.writeShellScript "sandbox-run-${appName}" ''
    set -eu
    ${lib.optionalString dedicated ''
      # Relay one of jrt's sockets/dirs into the app's runtime dir via
      # mount-helper.py (race-free; the source must be owned by jrt). The app
      # hasn't started yet (setpriv exec is last), so a failed relay is safe.
      # Args: <src> <target> <S|d>.
      __bind_checked() {
        ${mountHelper} relay "$1" "$2" "$3" ${uid}
      }
      # App's own runtime dir; jrt's session sockets bound in (ns-private, so they
      # never appear on the host) and ACL'd by the launcher. nixpak's own writes
      # (.flatpak, nixpak-bus, wayland proxy) then land in a dir the app owns.
      # FRESH each launch: it's the unit's RuntimeDirectory, which systemd removes
      # at stop (fd-based, never following a link) and makes root-owned 0700 at
      # start (its parent /run is root-owned, so the app can't swap the dir for a
      # symlink) — so the stale symlinks/mount targets the previous, possibly-
      # compromised, app uid left as a trap are gone. Anything still in it (a dir
      # left by an older build, or a removal that failed) systemd has chowned to
      # root at start; it's emptied here, as root, in a dir only root can write.
      # It stays ROOT-owned while root prepares it; ownership passes to the app only
      # right before the privilege drop (see the setpriv exec below).
      if [ "$(${co}/stat -c %u:%a "${runtimeDir}")" != 0:700 ]; then
        echo "sandbox-${appName}: ${runtimeDir} is not root's alone; refusing to start" >&2
        exit 1
      fi
      ${fu}/find "${runtimeDir}" -xdev -mindepth 1 -delete
      # No PipeWire socket: it is the whole media graph (every microphone, every
      # app's sound, screen casts). Audio goes through PulseAudio below.
      ${lib.optionalString usesWayland ''
        # Wayland: the launcher's security-context socket at the pinned name.
        # Never the raw compositor socket — if it's missing, no display at all.
        ${co}/touch "${runtimeDir}/${waylandSocket}"
        __bind_checked "${wlSock}" "${runtimeDir}/${waylandSocket}" S || ${co}/rm -f "${runtimeDir}/${waylandSocket}" 2>/dev/null || true
      ''}
      ${lib.optionalString appCfg.capabilities.audio ''
        # Pulse: the sandbox broker's filtered socket for this app (playback;
        # recording only with the microphone capability and your approval), or
        # jrt's own without the broker, at the app's pulse/native.
        # Bind ONLY the socket FILE, never jrt's pulse dir. Reaching a
        # file bound at the app's own path needs no permission on jrt's dir — which
        # matters because jrt-side libpulse clients (pavucontrol, waybar, swayosd)
        # redo libpulse's "secure directory" setup and chmod jrt's pulse dir back to
        # 0700; on a dir carrying ACLs, chmod resets the ACL mask to ---, silently
        # cutting off every dedicated app's grant (transient no-audio: cubeb EACCES).
        # The socket carries its own grant (the broker ACLs it to the app's uid;
        # pipewire-pulse's is 0666), so the bind alone suffices.
        # Trade-off: a file bind pins the inode, so restarting the broker (or
        # pipewire-pulse) needs an app relaunch.
        # Cheap pre-filter, as jrt (pulseProbe); __bind_checked does the
        # authoritative, race-free check.
        __pn="${pulseSource}"
        if ${asUser} ${pulseProbe} "$__pn"; then
          ${co}/mkdir -m 0700 "${runtimeDir}/pulse"
          ${co}/touch "${runtimeDir}/pulse/native"
          __bind_checked "$__pn" "${runtimeDir}/pulse/native" S || ${co}/rm -f "${runtimeDir}/pulse/native" 2>/dev/null || true
        fi
      ''}
      # Cross-uid document portal: jrt's doc FUSE lives under jrt's 0700 runtime dir
      # (the app can't traverse there), so root relays it into the app's own runtime
      # dir. Scoped to this app's by-app/<appId> subtree (NOT the whole FUSE) so the
      # app can only reach its OWN granted documents — the doc portal returns paths
      # as-the-app-sees-them (its by-app view mounted at .../doc), so binding by-app/
      # <appId> at the identity path is correct AND is what nixpak does same-uid. The
      # FUSE is allow_other (our fork), so the app uid can read it; nixpak binds this
      # at jrt's identity path inside the sandbox (docBind).
      # Cheap pre-filter, as jrt (docProbe); __bind_checked does the
      # authoritative, race-free check.
      if ${asUser} ${docProbe}; then
        ${co}/mkdir -p "${runtimeDir}/doc"
        __bind_checked "${jrtRuntime}/doc/by-app/${appId}" "${runtimeDir}/doc" d || ${co}/rmdir "${runtimeDir}/doc" 2>/dev/null || true
      fi
      # D-Bus session bus goes through the jrt-side bridge (started by the launcher),
      # NOT the raw bus — the app's uid is rejected at D-Bus EXTERNAL auth.
      # __bind_checked refuses a symlinked / foreign-owned bridge socket.
      ${co}/touch "${runtimeDir}/bus"
      __bind_checked "${bridgeSock}" "${runtimeDir}/bus" S || ${co}/rm -f "${runtimeDir}/bus" 2>/dev/null || true
      # The sandbox broker's socket for this app (modules/system/sandbox-broker.nix;
      # the broker ACLs it for this uid), when the broker is running.
      if ${asUser} ${co}/test -S "${jrtRuntime}/sbx-broker/${appName}.sock"; then
        ${co}/touch "${runtimeDir}/sbx-broker.sock"
        __bind_checked "${jrtRuntime}/sbx-broker/${appName}.sock" "${runtimeDir}/sbx-broker.sock" S || ${co}/rm -f "${runtimeDir}/sbx-broker.sock" 2>/dev/null || true
      fi
    ''}
    ${lib.optionalString (needsWaylandDisplay && usesWayland) (
      if dedicated then
        ''
          # The relayed security-context socket, bound above at the pinned name.
          if [ -S "${runtimeDir}/${waylandSocket}" ]; then export WAYLAND_DISPLAY=${waylandSocket}; fi
        ''
      else
        ''
          # Same-uid: point the app at the launcher's security-context socket in
          # jrt's runtime dir (nixpak binds $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY). If
          # it's missing, name a socket that doesn't exist — leaving it unset would
          # make nixpak fall back to binding a raw $XDG_RUNTIME_DIR/wayland-0.
          # (Looked at as jrt: asUser.)
          if ${asUser} ${co}/test -S "${wlSock}"; then
            export WAYLAND_DISPLAY=sandbox-${appName}-wayland
          else
            export WAYLAND_DISPLAY=sandbox-${appName}-no-display
          fi
        ''
    )}
    ${
      # Stash grafts via mount-helper.py (race-free: the app owns every component
      # of the target path, and every step inside it runs as its owner).
      # Dedicated: intermediate dirs are chowned to the app uid so it can traverse
      # them — including ones pre-existing inside a mounted parent stash (e.g. a
      # chromium "Shared Dictionary" left jrt-owned 0700).
      # Parent-first order from storage.entries; a refusal aborts (set -e).
      lib.concatMapStringsSep "\n" (
        e:
        ''${mountHelper} graft "${e.stashPath}" "${appHome}" "${e.path}" ${e.type}${lib.optionalString dedicated " ${appUser}"}''
      ) stashEntries
    }
    ${
      # No cold-launch argv forwarding. URLs reach an ALREADY-RUNNING instance via
      # the launcher's OpenURL path below; we deliberately do NOT read a jrt-owned
      # .args file here. Reading it as root (pre-drop) was a file-read oracle: jrt
      # could symlink the path to /proc/<root-service>/environ and leak the root
      # phase's env secrets into the app's argv (observable via procfs), or point it
      # at /dev/zero/a FIFO for memory-exhaustion/hang. A cold launch just starts the
      # app with no args; the URL isn't forwarded (accepted tradeoff — click again
      # once it's up).
      if dedicated then
        ''
          __u=$(${co}/id -u ${appUser}); __g=$(${co}/id -g ${appUser})
          # Preparation is done: hand the runtime dir (and the pulse subdir, if
          # made) to the app. The subdir FIRST and the dir itself last, so no
          # chown ever runs inside a dir the app already owns; -h never follows a
          # link. Deliberately NOT recursive — the entries inside are bind mounts
          # of jrt's sockets and must keep their owner.
          if [ -d "${runtimeDir}/pulse" ] && [ ! -L "${runtimeDir}/pulse" ]; then
            ${co}/chown -h "${appUser}" "${runtimeDir}/pulse"
          fi
          ${co}/chown -h "${appUser}" "${runtimeDir}"
          ${lib.optionalString identity ''
            # appearAsUser. Every path here sits in a root-owned parent (/home,
            # /run, /run/user), so neither the user nor the app can redirect these
            # mounts; the shared binds below the stage are resolved later by bwrap,
            # as the app's uid. Recursive: the stash grafts above, and the user's
            # impermanence mounts, come along. Private to this namespace. (The
            # stage is a RuntimeDirectory too: /run is read-only here. -n: no
            # utab bookkeeping, for the same reason.)
            ${ul}/mount -n --rbind -- "${sharedHome}" "${stageHome}"
            ${ul}/mount -n --rbind -- "${appHome}" "${sharedHome}"
            ${ul}/mount -n --rbind -- "${runtimeDir}" "${jrtRuntime}"
            export HOME="${sharedHome}" USER="${username}" LOGNAME="${username}"
            export XDG_RUNTIME_DIR="${jrtRuntime}"
            export DBUS_SESSION_BUS_ADDRESS="unix:path=${jrtRuntime}/bus"
            export PULSE_SERVER="unix:${jrtRuntime}/pulse/native"
          ''}
          exec ${lockHold} ${ul}/setpriv --reuid="$__u" --regid="$__g" --init-groups ${innerPkg}/bin/${binName}
        ''
      else
        ''
          exec ${lockHold} ${ul}/setpriv --reuid=${uid} --regid=${gid} --init-groups ${innerPkg}/bin/${binName}
        ''
    }
  '';

  # Idempotent removal of every u:app-<name> ACL entry the launcher grants on jrt's
  # LONG-LIVED objects (session sockets, bridge sock, shared jrt data like the
  # vault). Called from TWO places: the launcher's trap (the fast path) and the
  # unit's ExecStopPost (authoritative: it fires on unit deactivation even when the
  # launcher was SIGKILLed/OOM-killed and its trap never ran, which was the one
  # path that used to leak grants). Both run it AS JRT — the ExecStopPost through
  # asUser: every object here is jrt's, and an owner may change its own ACLs, so
  # root never walks jrt's home or runtime dir. Both runs are safe and
  # composable: `setfacl -x` only REMOVES an entry (never grants), so a double run
  # is a no-op; `-P` never follows a symlink (an argument or, in the recursive
  # walk, one jrt might plant to redirect it into a large tree: DoS). Entries are
  # per-uid, so removing THIS app's entry never disturbs another concurrent
  # dedicated app on the same shared socket. The per-app ~/Downloads/<app> folder
  # keeps its ACLs (jrt-owned; its default ACL keeps saved files jrt-readable);
  # only the traverse grants on ~ and ~/Downloads are removed. xhost and the
  # bridge are NOT here: xhost needs jrt's X-session context (ExecStopPost has
  # none), and the bridge dies via --die-with-parent — both stay in the trap. The
  # camera nodes are root's: revokeCameraScript. Only meaningful for dedicated
  # apps; every caller gates on `dedicated`.
  revokeAclsScript = pkgs.writeShellScript "sandbox-revoke-acls-${appName}" ''
    for __s in "${jrtRuntime}"/wayland-* "${jrtRuntime}"/pipewire-* "${jrtRuntime}/pulse"; do
      [ -e "$__s" ] || continue
      ${acl}/setfacl -R -P -x "u:${appUser}" "$__s" 2>/dev/null || true
    done
    ${acl}/setfacl -P -x "u:${appUser}" "${bridgeSock}" 2>/dev/null || true
    ${acl}/setfacl -P -x "u:${appUser}" "${wlSock}" 2>/dev/null || true
    ${lib.concatMapStringsSep "\n" (p: ''
      ${acl}/setfacl -R -P -x "u:${appUser}" "${sharedHome}/${p}" 2>/dev/null || true
    '') relExtraBinds}
    ${lib.concatMapStringsSep "\n" (d: ''
      ${acl}/setfacl -x "u:${appUser}" "${d}" 2>/dev/null || true
    '') sharedAncestors}
  '';
  # Camera nodes the attach helper granted this uid: root's nodes in root's /dev,
  # so only root (the ExecStopPost run) can undo it.
  revokeCameraScript = pkgs.writeShellScript "sandbox-revoke-camera-${appName}" ''
    for __n in /dev/video*; do
      [ -c "$__n" ] && ${acl}/setfacl -P -x "u:${appUser}" "$__n" 2>/dev/null || true
    done
  '';

  launcher = pkgs.writeShellScriptBin binName ''
    set -eu
    __dbus_pid=""
    __wl_pid=""
    ${lib.optionalString dedicated ''
      # Gates the trap's ACL revoke below. The unit's ExecStopPost is the
      # authoritative teardown and has already run by the time `systemctl start
      # --wait` returns for any launch that REACHED activation (clean quit OR crash).
      # Only a start that never activated the unit (e.g. a rejected polkit job) skips
      # ExecStopPost, so this stays 1 until a successful start clears it — then the
      # trap skips the redundant SECOND recursive setfacl walk over the shared-home
      # extraBinds trees on the normal-quit path (ExecStopPost already did that walk).
      __revoke_in_trap=1
    ''}
    ${lib.optionalString (appCfg.dbusName != "") ''
      # URL/file handling — ONLY for apps that declare a dbusName (URL handlers, e.g.
      # the browser). Every other systemd app skips this entirely and gets the plain
      # start-and-wait launcher below, unchanged.
      if ${pkgs.systemd}/bin/systemctl is-active --quiet ${unitName}.service; then
        # Already running: forward the URLs to the live instance and exit (systemctl
        # start would no-op, --wait would block). gecko remote: interface <dbusName>,
        # method OpenURL(ay) at /<dbusName-as-path>/Remote — the per-profile INSTANCE
        # is only in the bus name, so enumerate the live one from the prefix.
        if [ "$#" -gt 0 ]; then
          # Byte semantics for ''${#s} / ''${s:i:1} / printf "'c": under a UTF-8
          # locale they count characters and code points, which corrupts the
          # offsets (and code points > 255 make busctl reject the payload) for any
          # non-ASCII URL or cwd.
          export LC_ALL=C
          # Exact match on the bus-name column: the app's own name or a
          # <dbusName>.<instance> child. Dots escaped, anchored at both ends — a
          # loose prefix grep would also accept e.g. org.mozillaXzen or
          # org.mozilla.zenfoo. Only this app may OWN names under <dbusName>
          # (features/browser.nix), so a match is this app's live instance.
          __dest=$(${busctl} --user list --no-legend 2>/dev/null | ${awk} '{print $1}' \
            | ${grep} -xE '${lib.escapeRegex appCfg.dbusName}(\.[A-Za-z0-9_-]+)*' | ${co}/head -1 || true)
          [ -z "''${__dest:-}" ] && __dest="${appCfg.dbusName}"
          __path="/$(${co}/printf '%s' "${appCfg.dbusName}" | ${co}/tr . /)/Remote"
          # gecko's OpenURL(ay) payload is a mozilla-serialized COMMAND LINE, not a bare
          # URL: uint32 argc, then argc × uint32 absolute byte-offset of each argv, then
          # cwd\0, argv[0]\0 … argv[argc-1]\0 (header = 4 + 4*argc bytes; offset[i] =
          # header + len(cwd)+1 + Σ_{k<i}(len(argv[k])+1)). We forward the WHOLE command
          # line the URL handler was invoked with — argv[0]=the binary (program slot the
          # receiver ignores), argv[1..]="$@" (e.g. `--name zen-beta <url>`) — in ONE
          # call, so gecko consumes its own flags and opens the URL, exactly as a native
          # `zen-beta … <url>` forward does. Wire format captured from a live zen forward
          # and confirmed (receiver method-returns, tab opens). Sent as busctl `ay <n> …`.
          __enc_u32() { ${co}/printf '%d %d %d %d' $(( $1 & 255 )) $(( ($1 >> 8) & 255 )) $(( ($1 >> 16) & 255 )) $(( ($1 >> 24) & 255 )); }
          __enc_str() {
            __s=$1; __i=0; __len=''${#__s}; __o=""
            while [ "$__i" -lt "$__len" ]; do
              __c=''${__s:$__i:1}; __o="$__o $(${co}/printf '%d' "'$__c")"; __i=$(( __i + 1 ))
            done
            ${co}/printf '%s 0' "$__o"
          }
          __cwd="$PWD"
          # argv[0] = program slot; then the forwarded args verbatim.
          set -- "${innerPkg}/bin/${binName}" "$@"
          __argc=$#
          __cur=$(( 4 + 4 * __argc + ''${#__cwd} + 1 ))
          __offs=""; __blob=""
          for __a in "$@"; do
            __offs="$__offs $(__enc_u32 "$__cur")"
            __blob="$__blob $(__enc_str "$__a")"
            __cur=$(( __cur + ''${#__a} + 1 ))
          done
          __bytes="$(__enc_u32 "$__argc") $__offs $(__enc_str "$__cwd") $__blob"
          __count=$(set -- $__bytes; echo $#)
          ${busctl} --user call "$__dest" "$__path" "${appCfg.dbusName}" \
            OpenURL ay $__count $__bytes >/dev/null 2>&1 || true
        fi
        exit 0
      fi
      # Not running: fall through to start the service. Cold-launch URL/file args are
      # intentionally NOT forwarded — the old jrt-owned .args stash was a root-read
      # oracle (see runScript). The app opens; click the link again once it's up.
    ''}
    ${lib.optionalString (lockCheck != "") ''
      # Its VM is running: say so here, in the session (the unit's own lock,
      # runScript, would refuse too, but only to the journal).
      ${lockCheck}
    ''}
    # Teardown trap, installed BEFORE any grant below: if the launcher dies (set -e,
    # SIGINT) between granting ACLs / starting the bridge and `systemctl start`,
    # nothing would ever revoke them (the unit never ran, so neither did its
    # ExecStopPost). The unit is only stopped if THIS launcher started it, so an
    # early failure can't take down an instance another launch is running.
    __started=0
    trap '${
      lib.optionalString (
        dedicated && cfg.sandbox.x11Forward
      ) "${xhost} -SI:localuser:${appUser} >/dev/null 2>&1 || true; "
    }${lib.optionalString dedicated "if [ \"$__revoke_in_trap\" = 1 ]; then ${revokeAclsScript}; fi; "}if [ -n "$__dbus_pid" ]; then kill "$__dbus_pid" 2>/dev/null || true; fi; if [ -n "$__wl_pid" ]; then kill "$__wl_pid" 2>/dev/null || true; fi; if [ "$__started" = 1 ]; then ${pkgs.systemd}/bin/systemctl stop ${unitName}.service >/dev/null 2>&1 || true; fi' EXIT INT TERM
    ${lib.optionalString usesWayland ''
      # Security-context socket for this launch, held by a background helper until
      # the trap kills it. The stale path is cleared first so the wait only
      # succeeds once THIS helper has renamed its committed socket into place.
      # Upstream: the launcher's display, else the pinned compositor socket.
      ${co}/rm -f "${wlSock}"
      XDG_RUNTIME_DIR=${jrtRuntime} WAYLAND_DISPLAY="''${WAYLAND_DISPLAY:-${waylandSocket}}" \
        ${wlSecure}/bin/wayland-security-context hold "${wlSock}" ${lib.escapeShellArg appId} &
      __wl_pid=$!
      for __i in $(${co}/seq 1 100); do [ -S "${wlSock}" ] && break; kill -0 "$__wl_pid" 2>/dev/null || break; ${co}/sleep 0.05; done
      if [ ! -S "${wlSock}" ]; then
        echo "sandbox-${appName}: could not create a secure Wayland socket; refusing to start" >&2
        exit 1
      fi
    ''}
    ${
      if dedicated then
        ''
          # ACL teardown lives in ${revokeAclsScript} (defined above), invoked from
          # BOTH the trap below (fast path) and the unit's ExecStopPost (also as jrt,
          # authoritative — so a SIGKILL/OOM of this launcher, which skips the
          # trap, still gets grants revoked on unit deactivation). See that script.
          # Grant app-${appUser} rw on ONLY the specific session sockets (which the
          # runScript binds into the app's own runtime dir). No ACL on jrt's
          # runtime dir itself → app-${appUser} can't list/create/delete there.
          # NOT the raw wayland-* sockets: the app's display is the secure one.
          # Pulse is NOT here: the runScript binds pulse/native (the broker's
          # socket, ACL'd by the broker; without it pipewire-pulse's, 0666)
          # directly, and an ACL on jrt's pulse DIR is a trap — jrt-side libpulse
          # clients chmod that dir 0700, zeroing the ACL mask (see runScript).
          # Nor PipeWire: the app gets no PipeWire socket (the whole media graph);
          # a portal screen cast hands it a remote fd over D-Bus instead.
          # (revokeAclsScript still sweeps wayland-*, pipewire-* and pulse to clear
          # grants left by older builds.)
          ${lib.optionalString usesWayland ''
            ${acl}/setfacl -m "u:${appUser}:rw" "${wlSock}" 2>/dev/null || true
          ''}
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
          # Checked HERE, not inside the backgrounded bwrap below: a failed
          # expansion there only kills that child and the launch would carry on
          # with no bus.
          if [ -z "''${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
            echo "sandbox-${appName}: no session bus (DBUS_SESSION_BUS_ADDRESS unset); refusing to start" >&2
            exit 1
          fi
          ${bwrap} \
            --ro-bind-try /etc /etc \
            --ro-bind /nix/store /nix/store \
            --bind-try /var /var \
            --bind-try /tmp /tmp \
            --bind /run /run \
            --ro-bind-try "${flatpakInfoFile}" /.flatpak-info \
            --die-with-parent \
            -- ${dbusProxy} "$DBUS_SESSION_BUS_ADDRESS" "${bridgeSock}" ${bridgeFilterArgs} &
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
          # Shared jrt data (extraBinds, sharedDownloads): traverse every ancestor,
          # rw the shared trees. -P, as the revoke: a shared path that is itself a
          # symlink gets no grant (setfacl would otherwise follow it, and the
          # revoke wouldn't, leaving the target's ACLs behind for good).
          ${lib.concatMapStringsSep "\n" (d: ''
            ${acl}/setfacl -m "u:${appUser}:x" "${d}" 2>/dev/null || true
          '') sharedAncestors}
          ${lib.concatMapStringsSep "\n" (p: ''
            ${acl}/setfacl -R -P -m "u:${appUser}:rwX" "${sharedHome}/${p}" 2>/dev/null || true
          '') relExtraBinds}
          ${lib.optionalString cfg.sandbox.sharedDownloads ''
            # Per-app shared downloads (traverse comes from sharedAncestors). A
            # default ACL makes files the app creates jrt-accessible too.
            ${acl}/setfacl -R -P -m "u:${appUser}:rwX" "${sharedHome}/Downloads/${appName}" 2>/dev/null || true
            ${acl}/setfacl -d -m "u:${appUser}:rwX" "${sharedHome}/Downloads/${appName}" 2>/dev/null || true
          ''}
        ''
      else
        ""
    }
    ${lib.optionalString (dedicated && cfg.sandbox.x11Forward) ''
      # Grant the dedicated app uid access to jrt's X server via server-interpreted
      # localuser auth (no Xauthority cookie needed). Revoked in the trap above. Shares
      # jrt's X — see nixos/modules/apps/xwayland-forward.md for the caveats.
      ${xhost} +SI:localuser:${appUser} >/dev/null 2>&1 || true
    ''}
    ${lib.optionalString (camera && brokerOn && cfg.sandbox.vm.cameraOnLaunch) ''
      # Ask for the camera as the app starts (in the background); the broker
      # prompts, and the attach helper waits for the sandbox to be up.
      SBX_BROKER="${jrtRuntime}/sbx-broker/${appName}.sock" \
        ${sbxRequest}/bin/sbx-request camera --reason "${appName} was started" >/dev/null 2>&1 &
    ''}
    __rc=0
    __started=1
    ${pkgs.systemd}/bin/systemctl start --wait ${unitName}.service || __rc=$?
    ${lib.optionalString dedicated ''
      # Successful start ⇒ the unit reached activation and its ExecStopPost has
      # already revoked, so disarm the trap's revoke to avoid a second walk. A failed
      # start may be a rejected job that never activated (ExecStopPost never ran), so
      # leave the trap armed to guarantee teardown in that path.
      if [ "$__rc" = 0 ]; then __revoke_in_trap=0; fi
    ''}
    exit "$__rc"
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
  # Gate on `!dedicated`, the real same-uid systemd condition. (This used to key on
  # a cfg.sandbox.stashOwner option, since removed: the effective stash owner is now
  # derived from dedicatedUser at lowering in lib/apps.nix, and the old option was a
  # dead knob that made this assertion inert.) Matches injectAssertion's `!dedicated`.
  # Where the app may connect (lib/netpolicy.nix), enforced on this unit by
  # systemd's cgroup IP filter. Containers default to open; DNS goes through
  # resolved's stub on loopback, kept reachable in the restricted modes.
  # Where the app's pulse/native comes from (runScript): the broker's filter.
  pulseSource =
    if config.modules.sandbox.broker.enable then
      "${jrtRuntime}/sbx-broker/${appName}.pulse"
    else
      "${jrtRuntime}/pulse/native";

  netPolicy = (import ../netpolicy.nix { inherit lib; }).lower {
    policy = cfg.sandbox.network;
    backendDefault = "open";
    dns = if config.services.resolved.enable then [ "127.0.0.53" ] else config.networking.nameservers;
  };

  ptraceAssertion = lib.optional (!dedicated) {
    assertion = builtins.toString (config.boot.kernel.sysctl."kernel.yama.ptrace_scope" or 0) != "0";
    message = ''
      sandbox app '${appName}' uses the systemd same-uid stash. Set
      kernel.yama.ptrace_scope >= 1 (via modules.system.hardening) so a same-uid
      process can't PTRACE_ATTACH and scrape the running app's memory. NOTE: this
      does NOT hide the stash from an unsandboxed same-uid shell via
      /proc/<pid>/root — only sandbox.dedicatedUser does that.
    '';
  };
  # Same-uid + inject would read a jrt-written env file into the ROOT ExecStart
  # (the runScript runs privileged before the setpriv drop). jrt can pre-create/race
  # that file (it may start the unit via polkit) and even the curated values are
  # newline-injectable, so LD_PRELOAD / loader env would execute as ROOT. So the
  # backend has no such mode: the unit reads no env file at all, and this refuses
  # the combination. Dedicated never needs one (Nix-derived env).
  injectAssertion = lib.optional (!dedicated && cfg.sandbox.envMode == "inject") {
    assertion = false;
    message = ''
      sandbox app '${appName}': systemd same-uid backend with envMode = "inject" is
      unsafe — a jrt-written env file read into the ROOT ExecStart is an
      LD_PRELOAD/loader-injection vector into a root process. Use
      envMode = "defaults" (Nix-derived env) for a same-uid systemd app, or run it
      under sandbox.dedicatedUser (which never reads a jrt env file).
    '';
  };
  # Read-only extra binds are bound by nixpak as the app's uid; a dedicated uid
  # would need jrt's data ACL'd to it, and those grants (below) are read-write.
  readOnlyBindsAssertion = lib.optional (dedicated && cfg.sandbox.extraBindsReadOnly != [ ]) {
    assertion = false;
    message = "sandbox app '${appName}': sandbox.extraBindsReadOnly isn't supported for a dedicated-uid app (systemd backend + dedicatedUser).";
  };

  # The unit's confinement. It runs as root (no User=: the root phase must
  # unshare, mount and setpriv), never unconfined (no "+" on any Exec line), and
  # what confines the root phase confines the app too (it's the unit's child), so
  # this is what the root phase touches plus what the app writes:
  #   - capabilities: CAP_SYS_ADMIN (unshare, mount), CAP_SETUID + CAP_SETGID
  #     (setpriv; mount-helper's owner-dropped children), CAP_CHOWN (handing
  #     /run/app-<name> over; a graft's foreign intermediates). No CAP_DAC_*:
  #     root only works in directories it owns, the rest is done as their owner.
  #     (The app itself is unprivileged; bwrap's user namespace gets its own
  #     full set there whatever this bounding set is.)
  #   - ProtectSystem=strict: all read-only but /dev, /proc, /sys and
  #       the app's runtime dir (+ the appearAsUser stage): RuntimeDirectory;
  #       its stash roots (the graft sources, written by the app);
  #       absolute extraBinds and binds.rw outside the homes (the app's).
  #   - ProtectHome=tmpfs: /home, /root, /run/user empty but for the user's home
  #     and runtime dir and the app's home (BindPaths), read-write: the app
  #     writes there (and through the doc portal's FUSE), the ExecStopPost
  #     revoke sets ACLs there; DAC decides what the app uid may touch. Every
  #     source here has only root-owned ancestors, so systemd resolves no path
  #     through a directory a user controls. (The absolute binds are the app's
  #     own config; ReadWritePaths only flips their mount to read-write.)
  stashRoots = lib.unique (map (e: lib.removeSuffix "/${e.path}" e.stashPath) stashEntries);
  absBindsRw = lib.filter (
    p: paths.isAbsolute p && !(lib.hasPrefix "${sharedHome}/" p) && !(lib.hasPrefix "${appHome}/" p)
  ) (cfg.sandbox.extraBinds ++ appCfg.capabilities.binds.rw);
  confinement = {
    CapabilityBoundingSet = "CAP_SYS_ADMIN CAP_SETUID CAP_SETGID CAP_CHOWN";
    ProtectSystem = "strict";
    ProtectHome = "tmpfs";
    BindPaths = lib.unique [
      sharedHome
      appHome
      "-${jrtRuntime}"
    ];
    ReadWritePaths = map (p: "-${p}") (stashRoots ++ absBindsRw);
  }
  // lib.optionalAttrs dedicated {
    RuntimeDirectory = [ "app-${appName}" ] ++ lib.optional identity "sandbox-user-home/${appName}";
    RuntimeDirectoryMode = "0700";
  };
in
{
  # Reused by the VM implementation's D-Bus proxy (lib/backends/vm.nix).
  inherit (innerNix) dbusArgs flatpakInfoFile appId;
  package = finalPkg;
  systemConfig = {
    systemd.tmpfiles.rules =
      storage.tmpfilesRules # dedicated → leaf owned app-<name>
      # Per-app shared-downloads subdir under jrt's ~/Downloads (which impermanence
      # already persists on /large). jrt-owned; the launcher ACLs it rwX for the app
      # uid. Mode is 0775, NOT 0755: the group bits are the POSIX ACL *mask*, and
      # chmod 0755 (which tmpfiles re-runs every activation) would clamp the mask to
      # r-x and strip the app's ACL write bit. 0775 keeps the mask rwx (group = users,
      # effectively just jrt; other stays r-x) so the app's write survives resetups.
      # Root making it in jrt's home is tmpfiles' own fd-safe walk (no symlink
      # followed, no unsafe owner transition) and only ever gives jrt a jrt-owned
      # dir; and it must exist before either implementation's first launch (the
      # VM's launcher grants on it too, lib/vm/instance.nix), so it stays here.
      ++ lib.optional (
        dedicated && cfg.sandbox.sharedDownloads
      ) "d ${sharedHome}/Downloads/${appName} 0775 ${username} users -";
    environment.persistence = storage.homePersistence;
    assertions = storage.assertions ++ ptraceAssertion ++ injectAssertion ++ readOnlyBindsAssertion;
    # Explicit unit name for the polkit start/stop/ref allowlist (sandbox.nix) —
    # not a prefix scan.
    modules.sandbox.units = [ "${unitName}.service" ];
    modules.sandbox.broker.sandboxes.${appName} = {
      label = "${appName} (container)";
      uid = if dedicated then appUser else null;
      netUnits = [ "${unitName}.service" ];
      audio = import ../audio-mode.nix appCfg.capabilities;
      # A dedicated uid's sandbox takes no folders of the user's while running
      # (as with its VM); the camera, yes.
      grantPaths = if dedicated then null else "${attachProg}";
      camera = if camera then "${attachProg}" else null;
    };
    modules.sandbox.broker.attach.${appName} = lib.mkIf brokerOn {
      inherit appId camera;
      appUser = if dedicated then appUser else null;
      unit = "${unitName}.service";
      paths = !dedicated;
    };
    modules.sandbox.dnsAllow = lib.optional (netPolicy.names != [ ]) {
      units = [ "${unitName}.service" ];
      inherit (netPolicy) names deny;
    };

    users.groups = lib.optionalAttrs dedicated { "app-${appName}" = { }; };
    users.users = lib.optionalAttrs dedicated {
      "app-${appName}" = {
        isSystemUser = true;
        group = "app-${appName}";
        home = appHome;
        createHome = true;
        # FIDO tokens' uaccess ACL only covers the seat user; the `fido` group
        # (udev rule in modules/system/sandbox.nix) lets a dedicated uid open them.
        extraGroups = lib.optional appCfg.capabilities.fido "fido";
      };
    };

    systemd.services.${unitName} = {
      description = "Sandboxed stash service: ${appName}";
      # LAUNCHER-PREPARED — do NOT let `nixos-rebuild switch` restart/stop this unit.
      # The in-session launcher (as jrt) sets up the session-socket ACLs and starts the
      # cross-uid D-Bus bridge, THEN `systemctl start --wait`s this unit. If switch
      # restarts it, the --wait returns, the launcher's trap tears the bridge down, and
      # systemd re-execs the app bare — no bridge, no ACLs — so the app's session bus
      # (portals/OpenURI/tray/notifications/keyring) goes dead while the app keeps
      # running. Leave the prepared instance alone; a changed definition takes effect on
      # the next quit-and-relaunch (which re-runs the launcher prep).
      restartIfChanged = false;
      stopIfChanged = false;
      serviceConfig = {
        Type = "exec";
        # Root (confined: see `confinement`) so it can unshare a mount ns and
        # graft the stash; runScript drops to the app principal via setpriv
        # before exec'ing the sandbox.
        ExecStart = "${pkgs.util-linux}/bin/unshare --mount --propagation private -- ${runScript}";
        Restart = "no";
        # No core dumps: a sandboxed app's core would write its memory — including
        # secrets like the Discord token this stash exists to hide — in plaintext
        # to /var/lib/systemd/coredump. (Also silences electron's spurious
        # speech-dispatcher thread-abort dumps.)
        LimitCORE = 0;
        IPAddressAllow = netPolicy.ipAddressAllow;
        IPAddressDeny = netPolicy.ipAddressDeny;
        # Restricted modes: netpolicy's slice, which also denies the host's and
        # LAN's public addresses (sbx-netlocal, modules/system/sandbox-dnsallow.nix).
        Slice = lib.mkIf (netPolicy.slice != null) netPolicy.slice;
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
        ++ lib.optionals needsWaylandDisplay [
          "XDG_RUNTIME_DIR=${runtimeDir}"
          "DBUS_SESSION_BUS_ADDRESS=unix:path=${runtimeDir}/bus"
        ]
        ++ lib.optionals dedicated [
          "LANG=${config.i18n.defaultLocale}"
        ];
      }
      # Authoritative ACL teardown on unit deactivation: the net for the one case
      # the launcher's trap misses, a SIGKILL/OOM of the launcher, after which the
      # app self-exits and the unit deactivates with the grants still on jrt's
      # sockets. jrt's objects as jrt (asUser: an owner may change its own ACLs),
      # the camera nodes as root. `-` so a revoke hiccup never marks the unit
      # failed; the scripts are idempotent so they compose with the trap's own run
      # on a clean quit. (xhost/bridge stay in the trap — see revokeAclsScript.)
      // lib.optionalAttrs dedicated {
        ExecStopPost = [
          "-${asUser} ${revokeAclsScript}"
        ]
        ++ lib.optional camera "-${revokeCameraScript}";
      }
      // confinement;
    };
  };
}
