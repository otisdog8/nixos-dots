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
  busctl = "${pkgs.systemd}/bin/busctl";
  xhost = "${pkgs.xorg.xhost}/bin/xhost";
  gdbus = "${pkgs.glib}/bin/gdbus";
  grep = "${pkgs.gnugrep}/bin/grep";
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

  # WAYLAND_DISPLAY is PINNED to the compositor's real socket name (Hyprland uses
  # wayland-1) rather than globbed wayland-* + first-match. Globbing was a
  # confused-deputy hole: a compromised jrt could pre-create a lexically-earlier
  # socket (e.g. wayland-0) in its own runtime dir and the launcher (root) would
  # bind/select it, letting jrt intercept a dedicated app's live display/input.
  # Pinning the known name closes that. Set for dedicated and same-uid `defaults`
  # mode; same-uid `inject` gets it from the env file. If the compositor is ever
  # reconfigured to a different socket name, update `waylandSocket` below.
  needsWaylandDisplay = dedicated || cfg.sandbox.envMode == "defaults";
  waylandSocket = "wayland-1";

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
      for __s in ${jrtRuntime}/${waylandSocket} ${jrtRuntime}/pipewire-* ${jrtRuntime}/pulse; do
        [ -e "$__s" ] || continue
        # Refuse a symlink or a non-socket/dir: a compromised jrt could plant one in
        # its own runtime dir to trick root into bind-mounting an arbitrary host file
        # (e.g. /etc/shadow) into the app's runtime as "wayland-1". Only relay the
        # real sockets (and the pulse dir) we expect. The wayland name is pinned (not
        # globbed) so jrt can't win by planting a lexically-earlier socket.
        [ -L "$__s" ] && continue
        { [ -S "$__s" ] || [ -d "$__s" ]; } || continue
        __n="$(${co}/basename "$__s")"
        if [ -d "$__s" ]; then ${co}/mkdir -p "${runtimeDir}/$__n"; else ${co}/touch "${runtimeDir}/$__n"; fi
        ${ul}/mount --bind "$__s" "${runtimeDir}/$__n" 2>/dev/null || true
      done
      # Cross-uid document portal: jrt's doc FUSE lives under jrt's 0700 runtime dir
      # (the app can't traverse there), so root relays it into the app's own runtime
      # dir. Scoped to this app's by-app/<appId> subtree (NOT the whole FUSE) so the
      # app can only reach its OWN granted documents — the doc portal returns paths
      # as-the-app-sees-them (its by-app view mounted at .../doc), so binding by-app/
      # <appId> at the identity path is correct AND is what nixpak does same-uid. The
      # FUSE is allow_other (our fork), so the app uid can read it; nixpak binds this
      # at jrt's identity path inside the sandbox (docBind).
      # Root follows this jrt-controlled source path, so refuse if jrt turned any
      # component (the doc mount, by-app, or by-app/<appId>) into a symlink pointing
      # root at some other host path. Confused-deputy guard (app only gets DAC access
      # either way, but don't let jrt choose the target).
      if [ -d "${jrtRuntime}/doc" ] \
         && [ ! -L "${jrtRuntime}/doc" ] \
         && [ ! -L "${jrtRuntime}/doc/by-app" ] \
         && [ ! -L "${jrtRuntime}/doc/by-app/${appId}" ]; then
        ${co}/mkdir -p "${runtimeDir}/doc"
        ${ul}/mount --bind "${jrtRuntime}/doc/by-app/${appId}" "${runtimeDir}/doc" 2>/dev/null || true
      fi
      # D-Bus session bus goes through the jrt-side bridge (started by the launcher),
      # NOT the raw bus — the app's uid is rejected at D-Bus EXTERNAL auth. Refuse a
      # symlinked bridge socket ([ -S ] alone would follow one).
      if [ -S "${bridgeSock}" ] && [ ! -L "${bridgeSock}" ]; then
        ${co}/touch "${runtimeDir}/bus"
        ${ul}/mount --bind "${bridgeSock}" "${runtimeDir}/bus" 2>/dev/null || true
      fi
    ''}
    ${lib.optionalString needsWaylandDisplay ''
      # Pinned, not globbed — see the waylandSocket comment above.
      if [ -e "${jrtRuntime}/${waylandSocket}" ]; then export WAYLAND_DISPLAY=${waylandSocket}; fi
    ''}
    ${lib.concatMapStringsSep "\n" (
      e:
      let
        comps = lib.filter (c: c != "") (lib.splitString "/" e.path);
        cumul = lib.foldl' (acc: c: acc ++ [ "${lib.last acc}/${c}" ]) [ appHome ] comps;
        # Every level BELOW appHome (which /home being root-owned makes unswappable).
        checkPaths = lib.tail cumul;
      in
      ''
        # Root-stage safety: the app owns its home, so verify NO component of the
        # graft path is an app-planted symlink BEFORE mkdir -p follows it (which
        # would make root create dirs under an app-chosen target). Fail closed.
        ${lib.concatMapStringsSep "\n" (p: ''
          if [ -L "${p}" ]; then echo "sandbox-${appName}: symlink in graft path '${p}'; refusing" >&2; exit 1; fi
        '') checkPaths}
        __t="${appHome}/${e.path}"
        # Create the bind TARGET matching the entry type: a file entry needs a file
        # mountpoint (mkdir here would make `mount --bind <file> <dir>` fail with
        # "wrong fs type"), a dir entry needs a directory.
        ${
          if e.type == "file" then
            ''
              ${co}/mkdir -p "$(${co}/dirname "$__t")"
              # A prior run (or an old buggy build that mkdir'd file targets) may have
              # left this as a DIRECTORY; `mount --bind <file> <dir>` then fails with
              # "wrong fs type". Clear a stale wrong-type mountpoint (rmdir fails safe if
              # it's unexpectedly non-empty) before creating the file mountpoint. Not a
              # symlink — the checkPaths guard above already refused one at this path.
              if [ -e "$__t" ] && [ ! -f "$__t" ]; then ${co}/rmdir "$__t"; fi
              [ -e "$__t" ] || ${co}/touch "$__t"
            ''
          else
            ''
              # Symmetric self-heal: clear a stale non-dir (e.g. a leftover file from a
              # type change) so mkdir yields a directory mountpoint.
              if [ -e "$__t" ] && [ ! -d "$__t" ]; then ${co}/rm -f "$__t"; fi
              ${co}/mkdir -p "$__t"
            ''
        }
        # Belt: confirm the realized path is still canonical (no symlink slipped in).
        if [ "$(${co}/realpath "$__t")" != "$__t" ]; then
          echo "sandbox-${appName}: graft target '$__t' resolved through a symlink; refusing" >&2
          exit 1
        fi
        ${lib.optionalString dedicated ''
          # Dedicated apps run as a DIFFERENT uid, so EVERY intermediate dir on the
          # graft path must be app-traversable. Root-created intermediates are 0755
          # (fine), but one that PRE-EXISTS inside a mounted parent stash — e.g. a
          # chromium "Shared Dictionary" left jrt-owned 0700 by a nixpak→dedicated
          # migration — would block the app. chown the intermediates (NOT the leaf,
          # which is about to be an app-owned mount) to the app uid. Idempotent; a
          # no-op on already-correct trees.
          ${lib.concatMapStringsSep "\n" (p: ''
            ${co}/chown ${appUser} "${p}" 2>/dev/null || true
          '') (lib.init checkPaths)}
        ''}
        # The stash SOURCE itself: a symlink (migration moved one in, or a malicious
        # jrt planted it) would make this bind follow to an attacker-chosen host path.
        # Require the real expected type, never a symlink.
        if [ -L "${e.stashPath}" ]; then echo "sandbox-${appName}: stash '${e.stashPath}' is a symlink; refusing" >&2; exit 1; fi
        if [ ! -${
          if e.type == "file" then "f" else "d"
        } "${e.stashPath}" ]; then echo "sandbox-${appName}: stash '${e.stashPath}' is not a ${e.type}; refusing" >&2; exit 1; fi
        ${ul}/mount --bind "${e.stashPath}" "$__t"
      ''
    ) stashEntries}
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
          __dest=$(${busctl} --user list --no-legend 2>/dev/null | ${grep} -oE '${appCfg.dbusName}[A-Za-z0-9._]*' | ${co}/head -1 || true)
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
    ${
      if dedicated then
        ''
          # Revoke (on quit, from the trap) every ACL the grants below add to jrt's
          # LONG-LIVED objects — the session sockets, the bridge socket, and shared
          # jrt data (the vault etc.). Without this the app's `u:app-<name>` entry
          # lingers on jrt's Wayland/PipeWire/Pulse sockets (screen/audio capture) and
          # on the vault after the app exits, standing access it no longer needs.
          # Entries are per-uid, so removing THIS app's entry never disturbs another
          # concurrent dedicated app's grant on the same shared socket. The per-app
          # ~/Downloads/<app> share is intentionally left intact (purpose-built, jrt-
          # owned, its default ACL keeps saved files jrt-readable).
          __revoke_acls() {
            for __s in "${jrtRuntime}"/wayland-* "${jrtRuntime}"/pipewire-* "${jrtRuntime}/pulse"; do
              [ -e "$__s" ] || continue
              ${acl}/setfacl -R -x "u:${appUser}" "$__s" 2>/dev/null || true
            done
            ${acl}/setfacl -x "u:${appUser}" "${bridgeSock}" 2>/dev/null || true
            ${lib.concatMapStringsSep "\n" (p: ''
              ${acl}/setfacl -R -x "u:${appUser}" "${sharedHome}/${p}" 2>/dev/null || true
              ${acl}/setfacl -x "u:${appUser}" "$(${co}/dirname "${sharedHome}/${p}")" 2>/dev/null || true
            '') (lib.filter (p: !(lib.hasPrefix "/" p) && !(lib.hasPrefix "." p)) cfg.sandbox.extraBinds)}
            ${lib.optionalString (
              (lib.filter (p: !(lib.hasPrefix "/" p) && !(lib.hasPrefix "." p)) cfg.sandbox.extraBinds) != [ ]
            ) ''${acl}/setfacl -x "u:${appUser}" "${sharedHome}" 2>/dev/null || true''}
          }
          # Grant app-${appUser} rw on ONLY the specific session sockets (which the
          # runScript binds into the app's own runtime dir). No ACL on jrt's
          # runtime dir itself → app-${appUser} can't list/create/delete there.
          for __s in "${jrtRuntime}"/wayland-* "${jrtRuntime}"/pipewire-* "${jrtRuntime}/pulse"; do
            [ -e "$__s" ] || continue
            # Mirror the root-side relay checks: never ACL a symlink or a non-socket/
            # non-dir (a compromised jrt could plant one to widen the ACL's reach).
            [ -L "$__s" ] && continue
            { [ -S "$__s" ] || [ -d "$__s" ]; } || continue
            ${acl}/setfacl -R -m "u:${appUser}:rwX" "$__s" 2>/dev/null || true
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
          # Shared jrt data (vault etc.): traverse the path + rw the tree.
          ${lib.concatMapStringsSep "\n" (p: ''
            ${acl}/setfacl -m "u:${appUser}:x" "${sharedHome}" 2>/dev/null || true
            ${acl}/setfacl -m "u:${appUser}:x" "$(${co}/dirname "${sharedHome}/${p}")" 2>/dev/null || true
            ${acl}/setfacl -R -m "u:${appUser}:rwX" "${sharedHome}/${p}" 2>/dev/null || true
          '') (lib.filter (p: !(lib.hasPrefix "/" p) && !(lib.hasPrefix "." p)) cfg.sandbox.extraBinds)}
          ${lib.optionalString cfg.sandbox.sharedDownloads ''
            # Per-app shared downloads: let the app uid reach ~/Downloads/${appName}
            # (traverse ~ and ~/Downloads, rw the per-app subdir). A default ACL makes
            # files the app creates jrt-accessible too.
            ${acl}/setfacl -m "u:${appUser}:x" "${sharedHome}" 2>/dev/null || true
            ${acl}/setfacl -m "u:${appUser}:x" "${sharedHome}/Downloads" 2>/dev/null || true
            ${acl}/setfacl -R -m "u:${appUser}:rwX" "${sharedHome}/Downloads/${appName}" 2>/dev/null || true
            ${acl}/setfacl -d -m "u:${appUser}:rwX" "${sharedHome}/Downloads/${appName}" 2>/dev/null || true
          ''}
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
    trap '${
      lib.optionalString (
        dedicated && cfg.sandbox.x11Forward
      ) "${xhost} -SI:localuser:${appUser} >/dev/null 2>&1 || true; "
    }${lib.optionalString dedicated "__revoke_acls; "}if [ -n "$__dbus_pid" ]; then kill "$__dbus_pid" 2>/dev/null || true; fi; ${pkgs.systemd}/bin/systemctl stop ${unitName}.service >/dev/null 2>&1 || true' EXIT INT TERM
    ${lib.optionalString (dedicated && cfg.sandbox.x11Forward) ''
      # Grant the dedicated app uid access to jrt's X server via server-interpreted
      # localuser auth (no Xauthority cookie needed). Revoked in the trap above. Shares
      # jrt's X — see nixos/modules/apps/xwayland-forward.md for the caveats.
      ${xhost} +SI:localuser:${appUser} >/dev/null 2>&1 || true
    ''}
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
  # Same-uid + inject reads a jrt-written EnvironmentFile into the ROOT ExecStart
  # (the `+unshare … runScript` runs privileged before the setpriv drop). jrt can
  # pre-create/race that file (it may start the unit via polkit) and even the curated
  # values are newline-injectable, so LD_PRELOAD / loader env would execute as ROOT.
  # Dedicated NEVER reads it (uses Nix-derived `defaults`); forbid it for same-uid.
  injectAssertion = lib.optional (!dedicated && cfg.sandbox.envMode == "inject") {
    assertion = false;
    message = ''
      sandbox app '${appName}': systemd same-uid backend with envMode = "inject" is
      unsafe — the jrt-written ${envFile} is read into the ROOT ExecStart, an
      LD_PRELOAD/loader-injection vector into a root process. Use
      envMode = "defaults" (Nix-derived env) for a same-uid systemd app, or run it
      under sandbox.dedicatedUser (which never reads a jrt env file).
    '';
  };
in
{
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
      ++ lib.optional (
        dedicated && cfg.sandbox.sharedDownloads
      ) "d ${sharedHome}/Downloads/${appName} 0775 ${username} users -";
    environment.persistence = storage.homePersistence;
    assertions = storage.assertions ++ ptraceAssertion ++ injectAssertion;
    # Explicit unit name for the polkit start/stop/ref allowlist (sandbox.nix) —
    # not a prefix scan.
    modules.sandbox.units = [ "${unitName}.service" ];
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
        ++ lib.optionals needsWaylandDisplay [
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
