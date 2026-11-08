# sbx-nix: a Nix daemon for the sandboxes that isn't root.
#
# Sandboxed apps that import lib/features/nix-store.nix (claude-code,
# gemini-cli, opencode, gsd, sandbox-shell, …) talk to this daemon instead of
# the host's, in their nixpak/container sandboxes (a VM has its own Nix). The
# host's nix-daemon runs as root and any client can reach its whole protocol
# (2026 alone: symlink-following in FOD output registration, an overflow, the
# repair-flag store-path replacement — root for any client), so the sandboxes
# never get its socket. This one runs as `sbx-nix`, serving a Nix
# local-overlay store (experimental feature local-overlay-store):
#
#   lower  the host's /nix/store, never written; its metadata is a snapshot of
#          the host's DB (dataDir/lower/db), opened read-only (immutable).
#   upper  dataDir/upper/store + its own DB (dataDir/state/db): what the
#          sandboxes build or substitute that the host doesn't have.
#          dataDir/upper is sbx-nix's and 0700, so nobody else reaches a file
#          in the upper layer straight (only through the overlay, nosuid).
#          Regenerable: stop sbx-nix-store and delete dataDir to start over.
#
# Ownership (the rule of lib/vm/root.py and sandbox-unit-audit.nix: root works
# only in root's own folders, or on what the owner opened, as the owner): every
# path PID 1, tmpfiles or a root step creates, binds or listens on sits in a
# folder only root can write. dataDir and dataDir/state are root's; what
# sbx-nix writes are its own folders in them (upper, signal, pins, log, home,
# state/{db,builds,gcroots,gc-socket,profiles,temproots}, state/gc.lock), made
# by tmpfiles in those root-owned parents. Nix runs fine with a stateDir it
# can't write once those exist. The roots daemon's socket is in root's
# state/gc-roots-socket. Root steps (lib/vm/root.py, sbx-vm-root nix-*) open
# what is sbx-nix's only in a child that has dropped to sbx-nix, never following
# a link (openat2 RESOLVE_NO_SYMLINKS).
#
# Mounts (sbx-nix-store: `sbx-vm-root nix-up`, a confined root unit that
# enters the host's mount namespace with CAP_SYS_ADMIN, CAP_SYS_CHROOT,
# CAP_SETUID, CAP_SETGID, and, until the two last drops (both before any
# work), CAP_SETPCAP, CAP_DAC_OVERRIDE and CAP_FOWNER. nix-up itself keeps the
# first four (lib/vm/root.py HOST_NS_CAPS); the overlay's mounter, a child,
# keeps CAP_SYS_ADMIN, CAP_DAC_OVERRIDE and CAP_FOWNER (NIX_MOUNTER_CAPS):
# overlayfs does its upper-layer work with its creator's credentials, so it
# needs DAC_OVERRIDE for work/work and sbx-nix's upper folders, and FOWNER for
# the chmod/utime Nix does on sbx-nix's files. sbx-nix still can't change a
# host file through it: the caller is checked first, on the overlay inode
# (root's file, root's mode). Copy-up runs as fsuid 0 and needs neither
# CAP_CHOWN nor CAP_FSETID. The mounter gets the upper layer as an fd sbx-nix
# opened, never a path to resolve again):
#   /run/sbx-nix/private/rw  overlayfs lowerdir=/nix/store,upperdir,workdir,
#                            index=off, redirect_dir=nofollow, metacopy=off;
#                            /run/sbx-nix/private is 0700 root and a
#                            private mount of itself, so it propagates nowhere
#                            and nobody else can reach it. The daemon binds it
#                            at /nix/store.
#   /run/sbx-nix/nix/store   a read-only clone of the host /nix/store (the
#                            base, made private before it's attached, so it is
#                            no peer of the host's store), with a read-only
#                            clone of the overlay on top
#   /run/sbx-nix/nix/var/nix/daemon-socket/socket   the daemon's socket
# A sandbox binds /run/sbx-nix/nix at /nix (lib/features/nix-store.nix), so
# it sees the merged store at /nix/store and the socket where Nix looks.
# Because it binds the PARENT of the mount point, mount propagation carries
# remounts into running sandboxes: while the overlay is down they see the base
# (the host store, minus upper-only paths) and then the new overlay. The old
# overlay lingers, detached, while a sandbox still has files open in it, hence
# index=off (the kernel then allows a second mount on the same upper).
#
# The lower changing underneath:
#   - New host paths: sbx-nix-snapshot copies the host's DB (SQLite's online
#     backup, through a read-only mount) and renames it into place every
#     minute when it has changed. The daemon opens its store per connection,
#     so the next connection sees the new copy; open ones keep reading the old
#     file. Until then a path the host added is unknown to the daemon, and the
#     daemon can't replace it: deleting a host directory through the overlay
#     needs write access to it (root's), so adding or building that path fails
#     ("making directory accessible for deletion") until the next snapshot;
#     only a single-file path gets shadowed by an upper copy.
#   - A path the host added after something looked it up through the overlay
#     stays invisible there (overlayfs caches the negative lookup) until a
#     remount; so do deleted host paths' stale entries.
#   - sbx-nix-refresh remounts (restarts sbx-nix-store; a fresh snapshot first,
#     so upper-only paths are gone from running sandboxes only for the mount
#     itself) when Nix asked for it (remount-hook), after a GC, or once the host
#     DB has changed since the last mount — only while the daemon is idle, a
#     restart kills its builds. Hourly, after each switch, after nix-gc. The
#     remount also clears the whiteouts at the top of the upper layer (a
#     deletion through the overlay of something the host also has leaves one,
#     hiding the host's copy), as sbx-nix.
#
# GC:
#   - Upper (sbx-nix-gc, weekly): `nix-store --gc` through the daemon. Only
#     upper-layer paths are ever deleted. Roots: the daemon's own gcroots and
#     temporary roots, plus runtime roots (paths open/mapped/in the environment
#     of any process — the sandboxes' among them) from sbx-nix-roots, a root
#     `nix store roots-daemon` (use-roots-daemon; sbx-nix can't read other
#     users' /proc). NOT the clients' `result` links: those are indirect roots
#     under the user's home, which the daemon can't read (ProtectHome; Nix
#     prints "cannot read potential root" and neither counts nor removes
#     them). So each GC drops everything no running process uses; a dangling
#     `result` is rebuilt (mostly substituted) on next use. It is a cache.
#     /nix/store/.links is the upper layer's own: an opaque directory (set by
#     nix-up on the fd sbx-nix opened), so neither the GC's link sweep nor an
#     `optimise` ever reaches the host's .links (root's: removing a host link
#     fails, and the GC with it). auto-optimise-store stays off.
#   - Lower (sbx-nix-pin, hourly and before nix-gc): upper paths reference host
#     paths the host's GC knows nothing about. sbx-nix-pin-list (sbx-nix)
#     writes the host paths in the upper DB that aren't in the upper layer
#     itself to dataDir/pins/want; sbx-nix-pin (root, `sbx-vm-root nix-pin`)
#     reads that file through an fd sbx-nix opened, takes only store-path
#     names (anything else refuses the list) and keeps one symlink into the
#     store per name in root's flat /nix/var/nix/gcroots/sbx-nix. So what
#     sbx-nix can do to the host's GC is keep host paths alive (any it names:
#     disk use), nothing else. A path an in-flight build has just started
#     using isn't pinned until the next run.
#
# Trust: the sandboxes are untrusted clients (no trusted-users), so they can't
# import unsigned input-addressed paths (content-addressed ones verify
# themselves), repair, or change the substituters. What any client CAN do,
# with no cheap way to restrict it in Nix (no setting limits these ops to
# trusted users): run the GC or `nix store delete` on unrooted upper paths
# itself (another sandbox's dangling results, and bypassing sbx-nix-gc's
# stale-snapshot check: with a stale snapshot that can delete a host path's
# upper copy, leaving a whiteout until the next remount), and see, through
# `--print-roots` (served by the root roots daemon), which store paths every
# process on the host is using. Builds run as sbx-nix in Nix's build sandbox
# (build-users-group is empty: no root to switch users), so a build that
# escaped it could write the upper layer — what every sandbox then runs — but
# not the host's store or anything the host runs. Fixed-output builds have the
# daemon's network: netpolicy's "internet" mode (no LAN, tailnet, link-local),
# plus loopback (see `net` below).
#
# Enabled on a desktop with /cache where some enabled sandboxed app uses
# lib/features/nix-store.nix; elsewhere the sandboxes keep the per-user chroot
# store (the feature's fallback).
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  cfg = config.modules.sandbox.nixDaemon;
  netpolicy = import ../../../lib/netpolicy.nix { inherit lib; };
  core = import ../../../lib/vm/core { inherit lib pkgs; };
  rootStep = core.hardening.rootStep;
  rootTool = "${import ../../../lib/vm/root.nix pkgs}/bin/sbx-vm-root";
  nix = config.nix.package;

  base = cfg.dataDir;
  run = "/run/sbx-nix";
  view = "${run}/nix";
  rw = "${run}/private/rw";
  socket = "${view}/var/nix/daemon-socket/socket";
  upperDir = "${base}/upper";
  upper = "${upperDir}/store";
  work = "${base}/work";
  state = "${base}/state";
  lowerState = "${base}/lower";
  logDir = "${base}/log";
  home = "${base}/home";
  signal = "${base}/signal";
  pins = "${base}/pins";
  snapshot = "${lowerState}/db/db.sqlite";
  # Written when Nix asks for a remount, or after a GC (sbx-nix's); the
  # refresh acts on it and nix-up clears it, as sbx-nix.
  flag = "${signal}/remount-needed";
  hostDb = "/nix/var/nix/db";
  gcrootsDir = "/nix/var/nix/gcroots/sbx-nix";
  # The sbx-nix-owned entries of the (root-owned) state dir; Nix makes the
  # rest of its tree inside them.
  stateDirs = [
    "db"
    "builds"
    "gcroots"
    "gc-socket"
    "profiles"
    "temproots"
  ];

  # A store URL as the value of another's query parameter.
  enc = builtins.replaceStrings [ "%" "?" "&" "=" ] [ "%25" "%3F" "%26" "%3D" ];
  remountHook = pkgs.writeShellScript "sbx-nix-remount-hook" ": > ${flag}";
  lowerUrl = "local?real=/nix/store&state=${lowerState}&read-only=true";
  storeUrl = lib.concatStrings [
    "local-overlay://?state=${state}&log=${logDir}&upper-layer=${upper}"
    "&use-roots-daemon=true&remount-hook=${remountHook}"
    "&lower-store=${enc lowerUrl}"
  ];

  settings = config.nix.settings;
  list = name: lib.concatStringsSep " " (map toString (settings.${name} or [ ]));
  # The daemon's whole configuration: none of the host's nix.conf applies.
  confDir = pkgs.writeTextDir "nix.conf" ''
    experimental-features = nix-command flakes local-overlay-store read-only-local-store
    store = ${storeUrl}
    build-users-group =
    sandbox = true
    sandbox-fallback = false
    allowed-users = ${lib.concatStringsSep " " (cfg.allowedUsers ++ [ "sbx-nix" ])}
    trusted-users =
    require-sigs = true
    auto-optimise-store = false
    substituters = ${list "substituters"} ${list "extra-substituters"}
    trusted-public-keys = ${list "trusted-public-keys"} ${list "extra-trusted-public-keys"}
    max-jobs = ${toString (settings.max-jobs or "auto")}
    cores = ${toString (settings.cores or 0)}
  '';

  path = lib.makeBinPath [
    pkgs.coreutils
    pkgs.findutils
    pkgs.gnugrep
  ];

  # sbx-nix: the host paths the upper DB lists that aren't in the upper layer
  # (pin-list); sbx-nix-pin makes them roots. Written beside, then renamed.
  pinList = pkgs.writeShellScript "sbx-nix-pin-list" ''
    set -euo pipefail
    PATH=${path}
    tmp=$(mktemp ${pins}/.want.XXXXXX); trap 'rm -f "$tmp"' EXIT
    ${nix}/bin/nix --extra-experimental-features nix-command \
      path-info --all --store unix://${socket} \
      | grep -E '^/nix/store/[0-9a-df-np-sv-z]{32}-[A-Za-z0-9+._?=-]+$' \
      | while IFS= read -r p; do
          n=''${p#/nix/store/}
          [ -e "${upper}/$n" ] || [ -L "${upper}/$n" ] || printf '%s\n' "$n"
        done | LC_ALL=C sort -u > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" ${pins}/want
    trap - EXIT
  '';

  gc = pkgs.writeShellScript "sbx-nix-gc" ''
    set -euo pipefail
    PATH=${path}
    # With a stale snapshot, the GC would take host paths added since for
    # garbage and delete them through the overlay (whiteouts). If the
    # snapshot ordered before this one didn't catch up, wait for it.
    wal=${hostDb}/db.sqlite-wal
    stale() { [ ${hostDb}/db.sqlite -nt ${snapshot} ] || { [ -s "$wal" ] && [ "$wal" -nt ${snapshot} ]; }; }
    # The snapshot catches up every minute; give it half an hour.
    for _ in $(seq 30); do stale || break; sleep 60; done
    if stale; then
      echo "sbx-nix: the snapshot of the host's DB stays stale; not collecting now" >&2
      exit 0
    fi
    ${nix}/bin/nix-store --store unix://${socket} --gc
    # Whiteouts it left, duplicates it deleted from the upper layer directly:
    # the next refresh remounts.
    : > ${flag}
  '';

  refresh = pkgs.writeShellScript "sbx-nix-refresh" ''
    set -euo pipefail
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnugrep
        config.systemd.package
      ]
    }
    systemctl -q is-active sbx-nix-store.service || exit 0
    # Whether to remount: the flag (sbx-nix's: looked at without following a
    # link) or a host DB newer than the mount.
    flag=$(find ${signal} -maxdepth 1 -name remount-needed -type f -print -quit)
    wal=${hostDb}/db.sqlite-wal
    if [ -z "$flag" ] && [ ! ${hostDb}/db.sqlite -nt ${run}/mounted ] \
      && ! { [ -s "$wal" ] && [ "$wal" -nt ${run}/mounted ]; }; then
      exit 0
    fi
    # Let a switch (or whatever else systemd is in the middle of) finish; our
    # own units' jobs (a GC waiting on this, say) don't count.
    for _ in $(seq 120); do
      [ -n "$(systemctl list-jobs --no-legend | grep -v ' sbx-nix-' || true)" ] || break
      sleep 5
    done
    # The daemon alone is one process; workers (a client connected, a build)
    # are more. A restart would kill them: try again later.
    cg=$(systemctl show -P ControlGroup sbx-nix-daemon.service)
    procs=/sys/fs/cgroup$cg/cgroup.procs
    if [ -n "$cg" ] && [ -r "$procs" ] && [ "$(wc -l < "$procs")" -gt 1 ]; then
      echo "sbx-nix: daemon busy, refresh deferred" >&2
      exit 0
    fi
    # The snapshot first, while the overlay is still up.
    systemctl start sbx-nix-snapshot.service
    systemctl restart sbx-nix-store.service
  '';

  # sbx-nix's units that only run a client: no capabilities, nothing writable
  # but what they name, AF_UNIX only. (No RestrictSUIDSGID: it fails openat2.)
  clientHardening = rootStep "" // {
    PrivateDevices = true;
    ProtectKernelTunables = true;
    UMask = "0022";
  };

  # Nix also reads ~/.config/nix/nix.conf, and sbx-nix's home is writable by
  # sbx-nix: point the user config at an empty file instead.
  clientEnv = {
    HOME = home;
    XDG_CACHE_HOME = "${home}/.cache";
    NIX_USER_CONF_FILES = "${pkgs.writeText "sbx-nix-no-user.conf" ""}";
  };

  # Fixed-output builds share the daemon's network: the internet, not the
  # LAN or tailnet (lib/netpolicy.nix "internet"; in its slice, which also
  # denies the host's and LAN's public addresses, when sbx-netlocal keeps that
  # up to date — otherwise the slice is closed). Loopback stays open: the
  # cgroup IP filter also applies to sockets in a build's own network
  # namespace, and test suites talk to 127.0.0.1 there. (That also leaves the
  # host's loopback services to FOD builds — which the sandboxes, on the
  # nixpak backend's open network, reach already.)
  net = netpolicy.lower {
    policy = {
      mode = "internet";
      allow = [ "localhost" ];
      deny = [ ];
      allowDns = true;
    };
    backendDefault = "internet";
    dns = if config.services.resolved.enable then [ "127.0.0.53" ] else config.networking.nameservers;
  };

  usesFeature = lib.any (m: m.appCfg.usesSandboxNix or false) (
    lib.attrValues config.modules.sandbox.containerMembers
  );
in
{
  options.modules.sandbox.nixDaemon = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.services.graphical-desktop.enable && config.fileSystems ? "/cache" && usesFeature;
      defaultText = lib.literalMD "a desktop with /cache where an enabled sandboxed app uses lib/features/nix-store.nix";
      description = "sbx-nix, the sandboxes' unprivileged Nix daemon (a local-overlay store over the host's).";
    };
    dataDir = lib.mkOption {
      type = lib.types.path;
      default = if config.fileSystems ? "/cache" then "/cache/sbx-nix" else "/var/lib/sbx-nix";
      defaultText = lib.literalExpression ''if config.fileSystems ? "/cache" then "/cache/sbx-nix" else "/var/lib/sbx-nix"'';
      description = ''
        Upper layer, its DB, the host-DB snapshot and the overlay's workdir.
        All regenerable (a cache), so the disposable /cache where there is one.
        Must be one filesystem (overlayfs: upperdir and workdir together), and
        every folder above it root's and writable by nobody else.
      '';
    };
    allowedUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ username ];
      description = "Users who may connect (the sandboxes run as the desktop user). sbx-nix itself is always allowed (GC, pins).";
    };
    gcDates = lib.mkOption {
      type = lib.types.str;
      default = "weekly";
      description = "When to collect the upper layer (systemd calendar).";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.sbx-nix = {
      isSystemUser = true;
      group = "sbx-nix";
      description = "Sandbox Nix daemon";
    };
    users.groups.sbx-nix = { };

    # lib/features/nix-store.nix: this host has sbx-nix (no fallback to the
    # chroot store when it's down).
    environment.etc."sbx-nix/enabled".text = "";

    # Every entry's parent is root's and writable by nobody else. Not the
    # mount points (nix-up makes those): tmpfiles would chmod what's mounted.
    systemd.tmpfiles.rules =
      map (d: "d ${d} 0755 root root -") [
        run
        view
        "${view}/var"
        "${view}/var/nix"
        base
        state
        "${state}/gc-roots-socket"
        lowerState
        # The lower store is opened read-only, but still wants these.
        "${lowerState}/db"
        "${lowerState}/profiles"
        "${lowerState}/profiles/per-user"
        "${lowerState}/gcroots"
        "${lowerState}/gcroots/per-user"
        "${lowerState}/temproots"
        gcrootsDir
      ]
      ++ [
        # In a sandbox this is /nix/var/nix/sbx-nix-view: a sandbox started
        # inside one reuses its view (lib/features/nix-store.nix).
        "f ${view}/var/nix/sbx-nix-view 0644 root root -"
        "d ${run}/private 0700 root root -"
        "d ${work} 0700 root root -"
        # The store's half in it (upper/store) is made by nix-up, as sbx-nix.
        "d ${upperDir} 0700 sbx-nix sbx-nix -"
        "d ${signal} 0755 sbx-nix sbx-nix -"
        "d ${pins} 0755 sbx-nix sbx-nix -"
        "d ${logDir} 0700 sbx-nix sbx-nix -"
        "d ${home} 0700 sbx-nix sbx-nix -"
        "f ${state}/gc.lock 0600 sbx-nix sbx-nix -"
      ]
      ++ map (d: "d ${state}/${d} 0755 sbx-nix sbx-nix -") stateDirs;

    # Root, its own folders only (the host DB read-only, the snapshot dir):
    # no capabilities.
    systemd.services.sbx-nix-snapshot = {
      description = "Sandbox Nix store: snapshot of the host's Nix DB";
      unitConfig.RequiresMountsFor = [
        base
        hostDb
      ];
      serviceConfig = rootStep "" // {
        Type = "oneshot";
        ExecStart = "${rootTool} nix-snapshot ${base}";
        ReadWritePaths = [ "${lowerState}/db" ];
        TimeoutStartSec = "10min";
      };
    };
    systemd.timers.sbx-nix-snapshot = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitInactiveSec = "1min";
        AccuracySec = "10s";
      };
    };

    # Root: the mounts, in the host's mount namespace (lib/vm/root.py nix-up,
    # as a VM's -prep unit stages: CAP_SYS_PTRACE opens PID 1's namespace,
    # CAP_SYS_ADMIN and CAP_SYS_CHROOT enter it; before that every other
    # capability goes, from every set. CAP_SETPCAP, CAP_DAC_OVERRIDE and
    # CAP_FOWNER go right after: the overlay's mounter, forked first, keeps
    # CAP_SYS_ADMIN, CAP_DAC_OVERRIDE and CAP_FOWNER alone (overlayfs works
    # with its creator's credentials: work/work, sbx-nix's upper folders, the
    # setattr Nix does on sbx-nix's files); both drop CAP_SETPCAP last). The upper layer is sbx-nix's: a
    # child that has dropped to sbx-nix works in it and opens it for the
    # mounter; root only sets the opaque mark on the .links that child opened.
    systemd.services.sbx-nix-store = {
      description = "Sandbox Nix store (overlay of the host store)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "sbx-nix-snapshot.service" ];
      after = [
        "local-fs.target"
        "systemd-tmpfiles-setup.service"
        "sbx-nix-snapshot.service"
      ];
      unitConfig.RequiresMountsFor = [
        base
        "/nix/store"
      ];
      serviceConfig =
        rootStep [
          "CAP_SYS_ADMIN"
          "CAP_SYS_CHROOT"
          "CAP_SYS_PTRACE"
          "CAP_SETPCAP"
          "CAP_SETUID"
          "CAP_SETGID"
          # The overlay's mounter only (lib/vm/root.py NIX_MOUNTER_CAPS).
          "CAP_DAC_OVERRIDE"
          "CAP_FOWNER"
        ]
        // {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${rootTool} nix-up ${base}";
          # Also after a failed start (ExecStop wouldn't run).
          ExecStopPost = "${rootTool} nix-down";
          PrivateDevices = true;
          ProtectKernelTunables = true;
          # setns into the host's mount namespace.
          RestrictNamespaces = "mnt";
          SystemCallFilter = [
            "@system-service"
            "@mount"
          ];
        };
    };

    # Not ordered after the store: a connection queues here while the store
    # restarts, and starting the daemon pulls the store in.
    systemd.sockets.sbx-nix-daemon = {
      description = "Sandbox Nix daemon socket";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ socket ];
      # Who may use it is the daemon's allowed-users (checked before anything
      # else), like the host daemon's socket.
      socketConfig.SocketMode = "0666";
    };

    systemd.services.sbx-nix-daemon = {
      description = "Sandbox Nix daemon (unprivileged, local-overlay store)";
      requires = [ "sbx-nix-store.service" ];
      after = [
        "sbx-nix-store.service"
        "sbx-nix-roots.socket"
      ];
      wants = [ "sbx-nix-roots.socket" ];
      # Restarts (remounts) take the daemon down first.
      partOf = [ "sbx-nix-store.service" ];
      environment = clientEnv // {
        NIX_CONF_DIR = "${confDir}";
        NIX_STATE_DIR = state;
        NIX_LOG_DIR = logDir;
      };
      serviceConfig = {
        ExecStart = "${nix}/bin/nix-daemon --daemon";
        User = "sbx-nix";
        Group = "sbx-nix";
        # Its own view: the overlay at /nix/store, none of the host's Nix
        # state (the root daemon's socket and DB among it), the user's homes
        # (the indirect roots, see the GC note above) invisible.
        BindPaths = [ "${rw}:/nix/store" ];
        TemporaryFileSystem = [ "/nix/var:ro" ];
        ReadWritePaths = [
          upperDir
          state
          logDir
          home
          signal
        ];
        ReadOnlyPaths = [ lowerState ];
        InaccessiblePaths = [
          "-${work}"
          "-${pins}"
        ];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateIPC = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        # Nix's build sandbox: user, mount, pid, ipc, uts and (non-FOD builds)
        # net namespaces, a fresh /proc (so nothing may cover parts of /proc:
        # no ProtectKernelTunables/ProtectKernelLogs/ProtectProc), its own
        # hostname (no ProtectHostname: it filters sethostname everywhere),
        # personality for i686 and ADDR_NO_RANDOMIZE (no LockPersonality),
        # 32-bit syscalls for i686 builds (no SystemCallArchitectures), JITs
        # in builds (no MemoryDenyWriteExecute).
        RestrictNamespaces = [
          "user"
          "mnt"
          "pid"
          "ipc"
          "uts"
          "net"
          "cgroup"
        ];
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        RestrictRealtime = true;
        KeyringMode = "private";
        # The jail syscalls (lib/vm/core/hardening.nix jailedSyscallFilter)
        # plus the build sandbox's sethostname/setdomainname. Builds run under
        # it too: one that needs ptrace or perf (@debug) fails with EPERM.
        SystemCallFilter = [
          "@system-service"
          "@mount"
          "@sandbox"
          "sethostname"
          "setdomainname"
          "~@obsolete @raw-io @reboot @swap @module @cpu-emulation @debug @clock"
        ];
        SystemCallErrorNumber = "EPERM";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
        IPAddressAllow = net.ipAddressAllow;
        IPAddressDeny = net.ipAddressDeny;
        Slice = lib.mkIf config.modules.sandbox.netLocal.enable net.slice;
        UMask = "0022";
      };
    };

    # Runtime roots for the daemon's GC (use-roots-daemon): root, to read every
    # process's /proc entries. It only answers with store paths in use; the
    # socket (in root's state/gc-roots-socket) is the daemon's alone.
    systemd.sockets.sbx-nix-roots = {
      description = "Runtime GC roots for the sandbox Nix daemon";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "${state}/gc-roots-socket/socket" ];
      unitConfig.RequiresMountsFor = [ base ];
      socketConfig = {
        SocketUser = "sbx-nix";
        SocketGroup = "sbx-nix";
        SocketMode = "0600";
        DirectoryMode = "0755";
      };
    };
    systemd.services.sbx-nix-roots = {
      description = "Runtime GC roots for the sandbox Nix daemon";
      serviceConfig =
        rootStep [
          "CAP_SYS_PTRACE"
          "CAP_DAC_READ_SEARCH"
        ]
        // {
          # With socket activation the state dir only has to exist.
          ExecStart = "${nix}/bin/nix --extra-experimental-features 'nix-command read-only-local-store' store roots-daemon --store 'local?state=/run/sbx-nix-roots&read-only=true'";
          RuntimeDirectory = "sbx-nix-roots";
          PrivateDevices = true;
        };
    };

    systemd.services.sbx-nix-gc = {
      description = "Collect the sandbox Nix store's upper layer";
      # A current snapshot first (see gc's own check).
      wants = [
        "sbx-nix-daemon.socket"
        "sbx-nix-snapshot.service"
      ];
      after = [
        "sbx-nix-daemon.socket"
        "sbx-nix-snapshot.service"
      ];
      onSuccess = [
        "sbx-nix-pin.service"
        "sbx-nix-refresh.service"
      ];
      environment = clientEnv;
      serviceConfig = clientHardening // {
        Type = "oneshot";
        User = "sbx-nix";
        Group = "sbx-nix";
        ExecStart = gc;
        TimeoutStartSec = "2h";
        ReadWritePaths = [
          signal
          home
        ];
      };
    };
    systemd.timers.sbx-nix-gc = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.gcDates;
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };

    systemd.services.sbx-nix-pin-list = {
      description = "List the host store paths the sandbox Nix store needs";
      wants = [ "sbx-nix-daemon.socket" ];
      after = [ "sbx-nix-daemon.socket" ];
      environment = clientEnv;
      serviceConfig = clientHardening // {
        Type = "oneshot";
        User = "sbx-nix";
        Group = "sbx-nix";
        ExecStart = pinList;
        ReadWritePaths = [
          pins
          home
        ];
      };
    };
    # Root, root's gcroots folder only; sbx-nix's list arrives as data (an fd
    # a child dropped to sbx-nix opened): CAP_SETUID, CAP_SETGID for that child.
    systemd.services.sbx-nix-pin = {
      description = "Pin host store paths the sandbox Nix store needs";
      requires = [ "sbx-nix-pin-list.service" ];
      after = [ "sbx-nix-pin-list.service" ];
      before = [ "nix-gc.service" ];
      serviceConfig =
        rootStep [
          "CAP_SETUID"
          "CAP_SETGID"
        ]
        // {
          Type = "oneshot";
          ExecStart = "${rootTool} nix-pin ${base}";
          ReadWritePaths = [ gcrootsDir ];
          PrivateDevices = true;
          ProtectKernelTunables = true;
        };
    };
    systemd.timers.sbx-nix-pin = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "hourly";
        RandomizedDelaySec = "5min";
      };
    };

    # Root, no capabilities: systemctl only.
    systemd.services.sbx-nix-refresh = {
      description = "Remount the sandbox Nix store over the host's current store";
      after = [
        "sbx-nix-store.service"
        "nix-gc.service"
      ];
      serviceConfig = rootStep "" // {
        Type = "oneshot";
        ExecStart = refresh;
        PrivateDevices = true;
        ProtectKernelTunables = true;
      };
    };
    systemd.timers.sbx-nix-refresh = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "hourly";
        RandomizedDelaySec = "10min";
      };
    };
    # A switch (new system profile generation).
    systemd.paths.sbx-nix-refresh = {
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathChanged = "/nix/var/nix/profiles";
    };

    # The host's GC: pins first, a remount after (it may have deleted paths the
    # overlay still caches).
    systemd.services.nix-gc = lib.mkIf config.nix.gc.automatic {
      wants = [
        "sbx-nix-pin.service"
        "sbx-nix-refresh.service"
      ];
    };
  };
}
