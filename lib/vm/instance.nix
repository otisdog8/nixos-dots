# A sandbox VM instance: one crosvm microVM running one or more member apps.
#
# lib/backends/vm.nix makes a one-member instance per app, or points the app at
# its group's instance (modules.sandbox.groups, built in
# nixos/modules/system/sandbox-vm.nix). Everything below is aggregated over the
# members: storage, binds, capabilities, D-Bus policy, relay services.
#
#   - The VMM runs as the uid that owns the members' stashes (`principal`: the
#     user, or app-<name> for a systemd dedicatedUser app). Each storage entry is
#     bind-mounted (by systemd, as root, BindPaths=) into a per-tier tree inside the
#     unit's private mount namespace, shared over crosvm's jailed virtio-fs device
#     (sbx-<tier>), and grafted back onto ~/<path> in the guest (lib/vm/guest.nix).
#     The guest user appears as that uid on the host (single-entry uidmap), so
#     nothing is chowned when switching between container and vm.
#   - perCwd instances are one VM per project directory: a template unit
#     sandbox-vm-<name>@<escaped path>, the directory shared at the same absolute
#     path. Groups share their declared `projects` instead.
#   - The guest is the host-wide generic system (modules.sandbox.vm.guest) booting
#     from the host's read-only /nix/store; the instance's spec (a store path on
#     the kernel command line) tells it what to mount.
#   - A member's launcher (the app's command, run as the user) starts the unit
#     through the polkit allowlist, then runs the app over SSH on vsock with keys
#     generated fresh by root for every VM start. Unless the instance is
#     persistent, the last session out stops the VM.
#   - network → a virtio-net NIC backed by passt in its own unit, as the principal,
#     under the network policy (lib/netpolicy.nix; VMs default to "internet"). No
#     member with the network capability → no NIC at all.
#   - wayland (gui.nix) → windows on the host compositor through a
#     wp_security_context_v1 socket (the -wl unit), carried by virtio-nvgpu (which
#     also gives the guest the host GPU) or crosvm's cross-domain virtio-gpu, per
#     modules.sandbox.vm.graphics. X11 apps get xwayland-satellite in the guest.
#   - audio → the sandbox broker's filtered PulseAudio socket (playback;
#     recording only with the microphone capability, after approval), and the
#     members' D-Bus policy → a
#     filtered xdg-dbus-proxy with the (first) member's flatpak identity (portals,
#     notifications, OpenURI), both over a vsock relay that answers only this
#     VM's CID.
#   - folder grants (VMs that run as the user): a second virtio-fs share of the
#     whole home behind crosvm's dynamic path allowlist, which starts empty
#     (lib/vm/grants.py). The broker's grant-path, and group launchers started in
#     an undeclared folder of ~ (grantCwd), add a folder to the allowlist, and a
#     root agent in the guest binds it at its real path. Grants last until the
#     VM stops; "read-only" is the guest's bind only (the share allows writes).
#   - documents → the document portal's by-app view for the VM's flatpak
#     identity, shared at $XDG_RUNTIME_DIR/doc as flatpak binds it, so portal
#     file-chooser results (and drag and drop) resolve inside the guest.
#   - fido → a virtual CTAPHID security key in the guest (uhid), relayed through
#     the broker (prompted once) to whichever key is plugged in when it's used,
#     so keys can be hotplugged. The broker only relays the channels the guest
#     opened, never the host's own traffic with the key.
#
# Security shape: the apps' code runs behind KVM; the host-side attack surface is
# crosvm (per-device minijail processes with seccomp, the main process confined by
# the systemd unit below), passt, the GPU backend and the relay. The VMM uid can
# reach only the members' stashes and the explicitly shared paths. (BindPaths=
# sources are resolved against the host root, not the namespace being built —
# systemd's namespace.c — so hiding /home and /persist from the unit doesn't hide
# them from its binds.)
{
  config,
  lib,
  pkgs,
}:
{
  # Instance name: units sandbox-vm-<name>, runtime dir /run/sandbox-vm/<name>.
  name,
  # For unit descriptions.
  label ? name,
  # Member records (lib/backends/vm.nix `member`), at least one.
  members,
  perCwd ? false,
  # Keep running after the last session exits (stop with `sandbox-vm stop`).
  persistent ? false,
  # Absolute directories shared read-write at the same path (group projects).
  projects ? [ ],
  # Extra { path; ro; } binds, absolute or home-relative (group credentials).
  extraBinds ? [ ],
  # A launcher started outside the shared folders grants the VM its $PWD
  # (groups: you ran the app there, which is the consent).
  grantCwd ? false,
  network,
  memory,
  vcpus,
  gpuMemoryMiB ? 1024,
  gpuMemoryProcessPercent ? 50,
  # "game": virtio-nvgpu's measured settings for games (`gameTuning` below).
  tuning ? "default",
  # The host's Secret Service on this VM's bus (sandbox.vm.hostKeyring).
  hostKeyring ? false,
}:
let
  paths = import ../paths.nix { inherit lib; };
  netpolicy = import ../netpolicy.nix { inherit lib; };
  core = import ./core { inherit lib pkgs; };
  vmHost = config.modules.sandbox.vm;
  # This VM's shared-window size and per-process share as backend flags
  # (sandbox.vm.gpuMemoryMiB / gpuMemoryProcessPercent, a group's vm.* for a
  # group VM; lib/vm/nvgpu.nix `windowArgs`). The window is address space for
  # mapping GPU memory into the guest, not guest RAM or VRAM.
  nvgpuWindowArgs = vmHost.nvgpu.windowArgs {
    windowMiB = gpuMemoryMiB;
    ownerPercent = gpuMemoryProcessPercent;
    compute = gpuCap;
  };
  # Guest RAM faulted in and collapsed onto 2 MiB pages as the VM starts
  # (the fork's crosvm patch 0011), instead of one 4 KiB fault at a time on
  # first touch, which stalled frames for 20-40 ms. Commits all of the VM's RAM
  # at boot, so free-page reporting (which hands pages back) is off with it.
  prefault = nvgpu && vmHost.prefaultMemory;
  # Games (sandbox.vm.tuning = "game"; the fork's DEPLOY.md, "Frame pacing",
  # "Tuning" and "vCPU placement", measured on this host's CPU):
  #   - the VMM's threads get a 100 µs EEVDF slice (the backend sets its own by
  #     default): a woken vCPU gets a CPU back sooner on a loaded host;
  #   - one core-scheduling cookie for the VMM and its backend ("shared")
  #     instead of crosvm's one per vCPU: the backend thread answering a vCPU
  #     may run on its SMT sibling, nothing else of the host's or another VM's
  #     may (per-vCPU cookies cost ~12% fps and most of the 1% lows);
  #   - the vCPUs pinned in pairs on whole cores of the CPU's least-preferred
  #     L3 domain (the `smt` layout, the guest told they're siblings): lows that
  #     hold while the desktop loads the other CCD, for 3-8% of the average on an
  #     idle host. Two game VMs at once get the same cores. Unpinned if the
  #     layout can't be worked out (an odd count, too many vCPUs);
  #   - the guest kernel: transparent huge pages for every process, and ntsync
  #     (Wine/Proton's fast path; /dev/ntsync).
  gameTuning = nvgpu && tuning == "game";
  guest = vmHost.guest.config;

  first = lib.head members;
  inherit (first) username principal principalGroup;
  home = "/home/${username}";
  hostUser = config.users.users.${username};
  guestUid = toString hostUser.uid;
  guestGid = toString config.users.groups.${hostUser.group}.gid;

  anyCap = c: lib.any (m: m.caps.${c}) members;
  network' = anyCap "network";

  # ── Display and GPU (modules.sandbox.vm.graphics; guest side in
  # lib/vm/guest-graphics.nix) ─────────────────────────────────────────────────
  gui = anyCap "wayland" && vmHost.graphics != "none";
  x11 = gui && lib.any (m: m.caps.x11 || m.x11Forward) members;
  gpuCap = anyCap "gpu";
  # virtio-nvgpu carries both the GPU and the display; GPU-only apps get it too.
  # virtio-nvgpu only for VMs whose apps need the GPU (graphics = "auto"), or
  # for every GUI VM (graphics = "nvgpu"); every other GUI VM gets cross-domain,
  # which reaches no host GPU at all.
  nvgpu = vmHost.nvgpuAvailable && (gpuCap || (vmHost.graphics == "nvgpu" && gui));
  crossDomain = gui && !nvgpu;
  gpuDevice = nvgpu || crossDomain;
  crosvmPkg = if nvgpu then vmHost.nvgpu.crosvm else pkgs.crosvm;
  # The virtio-nvgpu backend runs as a user of this VM's own (virtio-nvgpu's
  # DEPLOY.md, "Per-VM users"), never the desktop user or the VMM's: a
  # compromised backend is then neither a step from the session nor the VMM.
  gpuUserName =
    let
      n = "sbx-gpu-${name}";
    in
    # 31: the longest group name NixOS accepts.
    if lib.stringLength n <= 31 then
      n
    else
      "sbx-gpu-${builtins.substring 0 16 (builtins.hashString "sha256" name)}";
  gpuUser = if nvgpu then gpuUserName else principal;
  # Zero-copy screen capture (virtio-nvgpu's "capture injection", DEPLOY.md):
  # the backend takes host dma-bufs on an inject socket from ONE helper user of
  # this VM's own (never the backend's, the VMM's or the desktop user's) and
  # makes them guest dma-bufs, opened in the guest through /dev/nvgpu-capture.
  # The D-Bus adapter obtains only the portal-approved PipeWire remote; the
  # dedicated capture helper injects buffers and the guest publishes them on
  # a private per-session PipeWire server. The portal is reached over the VM's
  # filtered bus, so no bus (an unsandboxed member: no policy, no identity)
  # means no capture — the adapter unit would otherwise require a -bus unit
  # that doesn't exist, and the VM would not start.
  capture = nvgpu && bus && lib.any (m: m.screenCast or false) members;
  captureUserName =
    let
      n = "sbx-cap-${name}";
    in
    # 31: the longest group name NixOS accepts.
    if lib.stringLength n <= 31 then
      n
    else
      "sbx-cap-${builtins.substring 0 16 (builtins.hashString "sha256" name)}";
  gpuGroup = if nvgpu then gpuUserName else principalGroup;
  # The guest's Wayland socket (mirrors guest-graphics.nix) and the host
  # compositor's, pinned like the systemd backend's.
  guestWaylandDisplay = if nvgpu then "/run/sbx/wl/wayland-0" else "wayland-0";
  guestRuntimeDir = "/run/user/${guestUid}";
  hostRuntimeDir = "/run/user/${guestUid}";
  hostWaylandSocket = "wayland-1";
  wlSecure = import ../backends/wayland-security-context.nix pkgs;

  # With allowNames the guest resolves through the host's resolved (passt
  # forwards its DNS there), which is where sbx-dnsallow sees the answers.
  dnsNames = (network.allowNames or [ ]) != [ ] && config.services.resolved.enable;
  netPolicy = netpolicy.lower {
    policy = network;
    backendDefault = "internet";
    dns = if dnsNames then [ "127.0.0.53" ] else vmHost.dns;
  };
  netUnitPattern = if perCwd then "${unit}-net@*.service" else "${unit}-net.service";

  # ── Host services over vsock (lib/vm/vsock-relay.py) ─────────────────────────
  # Audio: the broker's filtered PulseAudio socket for this VM (in front of
  # pipewire-pulse), no shm/memfd since file descriptors can't cross vsock. D-Bus: an xdg-dbus-proxy with the members' own
  # filter (the same policy the container backends apply) and a flatpak identity,
  # so the portals treat it as that sandboxed app.
  audio = anyCap "audio";
  dbusArgs = lib.unique (lib.concatMap (m: if m.dbusArgs == null then [ ] else m.dbusArgs) members);
  # The bus identity: the first member with a .flatpak-info, and its app id
  # (the document portal's by-app/<id> view).
  busMember = lib.findFirst (m: m.flatpakInfoFile != null) null members;
  flatpakInfoFile = if busMember == null then null else busMember.flatpakInfoFile;
  busAppId = if busMember == null then null else busMember.appId or null;
  bus = dbusArgs != [ ] && flatpakInfoFile != null;
  # sandbox.vm.hostKeyring: the host keyring (kwallet's Secret Service) too,
  # for this VM's proxy only. The container backends never get it.
  busArgs = dbusArgs ++ lib.optional hostKeyring "--talk=org.freedesktop.secrets" ++ [ "--filter" ];
  # The sandbox broker (modules/system/sandbox-broker.nix): escapes and grants.
  broker = config.modules.sandbox.broker.enable;
  brokerName = "vm-${name}";
  # Temporary folder grants (lib/vm/grants.py): a virtio-fs share of the user's
  # home behind an allowlist that starts empty. Only when the VM runs as the user.
  grants = principal == username;
  # A VM that runs as an app-<name> uid keeps the app's data from the user, so
  # the user's SSH key into it is restricted to starting its members (no shell,
  # no arguments, no environment of the user's): `forcedCommand` below.
  restricted = principal != username;
  # Files the portals hand this app (FileChooser results, drag and drop): the
  # document portal's view for the VM's flatpak identity, shared like flatpak
  # binds it (by-app/<id> at $XDG_RUNTIME_DIR/doc), so only this app's documents.
  docs = bus && busAppId != null;
  # Security keys: a virtual FIDO device in the guest, relayed through the
  # broker to whichever key is plugged in (lib/vm/fido-guest.py).
  fido = anyCap "fido" && broker;
  # Cameras: USB passthrough of the host's video-class devices into the running
  # VM, only on approval (the broker's camera op, or `sandbox-vm camera`), until
  # the VM stops. The VM has an xHCI controller only when it may get one.
  camera = anyCap "camera";
  grantCwd' = grantCwd && grants;
  grantsPkg = import ./grants.nix pkgs;
  crosvmFs = import ./crosvm-fs.nix pkgs;
  # Other modules' services (sandbox.vm.relays), merged across members.
  extraRelays = lib.foldl' (a: m: a // m.relays) { } members;
  builtinRelays = [
    "pulse"
    "dbus"
    "capture-dbus"
    "broker"
    "grants"
  ];
  relayServices =
    lib.optional audio "pulse"
    ++ lib.optional bus "dbus"
    ++ lib.optional broker "broker"
    ++ lib.optional grants "grants"
    ++ lib.attrNames extraRelays;
  relay = relayServices != [ ];
  vsockRelay = import ./vsock-relay.nix pkgs;
  sbxRequest = pkgs.writeScriptBin "sbx-request" (
    "#!${pkgs.python3}/bin/python3 -IS\n" + builtins.readFile ../broker/request.py
  );
  guestSockets = {
    pulse = "/run/sbx/pulse/native";
    dbus = "/run/sbx/bus/bus";
    broker = "/run/sbx/broker.sock";
  }
  // lib.mapAttrs (_: r: r.guest) extraRelays;
  guestBinds = lib.foldl' (a: m: a // m.guestBinds) { } members;
  guestServices = lib.foldl' (a: m: a // m.guestServices) { } members;
  pulseClientConf = pkgs.writeText "sandbox-vm-pulse-client.conf" ''
    enable-shm = no
    enable-memfd = no
    autospawn = no
  '';
  # The .flatpak-info plus the [Instance] group the portal's parser requires (as
  # lib/backends/systemd.nix does for its bridge).
  busInstance = "sandbox-vm-${name}";
  busFlatpakInfo = pkgs.runCommand "${unit}-flatpak-info" { } ''
    cat ${flatpakInfoFile} > "$out"
    printf '\n[Instance]\ninstance-id=${busInstance}\nsession-bus-proxy=true\nsystem-bus-proxy=true\n' >> "$out"
  '';

  unit = "sandbox-vm-${name}";
  tmpl = lib.optionalString perCwd "@";
  # Units reference each other per instance; scripts get the project path.
  ref = u: if perCwd then "${u}@%i.service" else "${u}.service";
  # %f = the instance unescaped as a path, with its leading "/" (%I drops it).
  instArg = lib.optionalString perCwd " \"%f\"";

  # /run/sandbox-vm/<name>: <id>/ holds one launch's keys and sockets (root prep,
  # removed on stop); tree/ and cwd/ are mount points for the unit's private binds
  # (empty on the host, so concurrent per-project instances can share them).
  base = "/run/sandbox-vm/${name}";
  tree = "${base}/tree";
  cwdMount = "${base}/cwd";

  co = "${pkgs.coreutils}/bin";
  crosvm = "${crosvmPkg}/bin/crosvm";
  systemctl = "${pkgs.systemd}/bin/systemctl";
  flock = "${pkgs.util-linux}/bin/flock";
  ssh = "${pkgs.openssh}/bin/ssh";

  # From $dir (the project path, "" otherwise): the launch id, its runtime dir and
  # the VM's vsock CID. Shared verbatim by the launchers and every unit script,
  # which is how a launcher finds the VM's keys and address.
  idPrelude = ''
    if [ -n "$dir" ]; then
      id="$(printf '%s' "$dir" | ${co}/sha256sum | ${co}/cut -c1-16)"
    else
      id=main
    fi
    rt="${base}/$id"
  ''
  + core.cid.appShell name;

  # ── Storage and binds ────────────────────────────────────────────────────────
  # Parent-first across all members (a parent must be grafted before its child).
  depth = p: lib.length (paths.components p);
  entries = lib.sort (a: b: depth a.path < depth b.path) (lib.concatMap (m: m.entries) members);
  tiers = lib.unique (map (e: e.tier) entries);
  entrySource = e: if e.location == "stash" then e.stashPath else "${home}/${e.path}";

  expandHome = p: if lib.hasPrefix "~/" p then lib.removePrefix "~/" p else p;
  expandHome' = p: if lib.hasPrefix "~/" p then "${home}/${lib.removePrefix "~/" p}" else p;
  bindReqs =
    lib.concatMap (m: m.bindReqs) members
    ++ map (b: b // { path = expandHome b.path; }) extraBinds
    ++ map (p: {
      path = expandHome p;
      ro = false;
    }) projects
    # GUI apps see the user's toolkit/theme settings, read-only (as gui.nix binds
    # them for the container backends); the theme files themselves come from the
    # host's system profile, which the launcher puts on XDG_DATA_DIRS.
    ++ lib.optionals gui (
      map
        (p: {
          path = p;
          ro = true;
        })
        [
          ".config/gtk-2.0"
          ".config/gtk-3.0"
          ".config/gtk-4.0"
          ".config/fontconfig"
          ".config/dconf"
          ".config/qt6ct"
          ".config/Kvantum"
        ]
    );
  pwdBinds = lib.filter (b: paths.isPwdRelative b.path) bindReqs;
  sourceOf = p: if paths.isAbsolute p then p else "${home}/${p}";
  # One bind per path, read-write if any member wants it writable. Absolute and
  # home-relative binds keep their host path inside the guest.
  bindSources = lib.unique (
    map (b: sourceOf b.path) (lib.filter (b: !(paths.isPwdRelative b.path)) bindReqs)
  );
  binds = lib.imap0 (i: source: {
    index = i;
    inherit source;
    ro = lib.all (b: !(paths.isPwdRelative b.path) -> sourceOf b.path != source || b.ro) bindReqs;
  }) bindSources;
  projectDirs = map (p: sourceOf (expandHome p)) projects;

  # One BindPaths= entry: "SRC":"DST". systemd splits source and destination on
  # the ':' BETWEEN words, so each side is quoted separately (paths may contain
  # spaces) — quoting the whole pair would make it one path. A leading "-" on the
  # source = skip if missing. Stash entries are hard: tmpfiles guarantees them,
  # and a missing one must fail the VM rather than silently run it without its data.
  bindPair = src: dst: ''"${src}":"${dst}"'';
  storageBinds = map (
    e:
    bindPair "${lib.optionalString (e.location == "home") "-"}${entrySource e}" "${tree}/${e.tier}/${e.path}"
  ) entries;
  bindTarget = b: "${tree}/binds/${toString b.index}";
  rwBinds = map (b: bindPair "-${b.source}" (bindTarget b)) (lib.filter (b: !b.ro) binds);
  roBinds = map (b: bindPair "-${b.source}" (bindTarget b)) (lib.filter (b: b.ro) binds);

  spec = pkgs.writeText "${unit}-spec.json" (
    builtins.toJSON {
      instance = name;
      inherit tiers x11;
      entries = map (e: { inherit (e) tier path; }) entries;
      binds = map (b: {
        inherit (b) index;
        target = b.source;
      }) binds;
      cwd = perCwd;
      inherit grants fido docs;
      # Which GPU/display stack the guest brings up (guest-graphics.nix).
      gpu = nvgpu;
      # The backend offers capture injection (/dev/nvgpu-capture in the guest).
      inherit capture;
      display =
        if nvgpu && gui then
          "nvgpu"
        else if crossDomain then
          "cross-domain"
        else
          null;
      guestBinds = lib.mapAttrsToList (target: source: {
        target = expandHome' target;
        inherit source;
      }) guestBinds;
      services = lib.mapAttrsToList (n: sv: {
        name = n;
        inherit (sv) argv group root;
        env = [
          "XDG_RUNTIME_DIR=${guestRuntimeDir}"
        ]
        ++ lib.optionals gui [ "WAYLAND_DISPLAY=${guestWaylandDisplay}" ]
        ++ lib.optionals bus [ "DBUS_SESSION_BUS_ADDRESS=unix:path=${guestSockets.dbus}" ];
      }) guestServices;
      # Guest sockets for the relay (the grant agent dials the host directly).
      relay = map (n: {
        name = if n == "dbus" && capture then "capture-dbus" else n;
        # Apps use the message-aware guest proxy; only that proxy needs this
        # raw FD-free transport to the host's filtering proxy.
        path = if n == "dbus" then "/run/sbx/bus/transport.sock" else guestSockets.${n};
      }) (lib.remove "grants" relayServices);
    }
  );

  # ── The app's environment in the guest ───────────────────────────────────────
  # Fixed parts: the guest's sockets, display and GPU loaders.
  fixedEnv =
    lib.optionals audio [
      "PULSE_SERVER=unix:${guestSockets.pulse}"
      "PULSE_CLIENTCONFIG=${pulseClientConf}"
    ]
    ++ lib.optional bus "DBUS_SESSION_BUS_ADDRESS=unix:path=${guestSockets.dbus}"
    ++ lib.optionals gui (
      [
        "XDG_RUNTIME_DIR=${guestRuntimeDir}"
        "WAYLAND_DISPLAY=${guestWaylandDisplay}"
      ]
      ++ lib.optional x11 "DISPLAY=:0"
      ++ (
        if nvgpu then
          # Pin every loader to NVIDIA's files (as virtio-nvgpu's guest does), so
          # a broken NVIDIA ICD fails loudly instead of falling back to Mesa.
          [
            "VK_DRIVER_FILES=/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.json"
            "__EGL_VENDOR_LIBRARY_FILENAMES=/run/opengl-driver/share/glvnd/egl_vendor.d/10_nvidia.json"
            "__GLX_VENDOR_LIBRARY_NAME=nvidia"
            "GBM_BACKENDS_PATH=/run/opengl-driver/lib/gbm"
          ]
        else
          # No host GPU behind cross-domain: render in software.
          [
            "LIBGL_ALWAYS_SOFTWARE=1"
            "GALLIUM_DRIVER=llvmpipe"
          ]
      )
    );
  # gui.nix's defaults, for launches from outside the session environment (and
  # all a restricted VM gets for these).
  guiDefaults = [
    "NIXOS_OZONE_WL=1"
    "ELECTRON_OZONE_PLATFORM_HINT=wayland"
    "MOZ_ENABLE_WAYLAND=1"
    "QT_QPA_PLATFORM=wayland;xcb"
    "QT_QPA_PLATFORMTHEME=qt6ct"
    "XDG_CURRENT_DESKTOP=Hyprland"
    "XDG_SESSION_TYPE=wayland"
  ];
  # Members first on PATH, so they can run each other.
  memberPath =
    member:
    lib.concatMapStrings (m: "${m.package}/bin:") (
      [ member ] ++ lib.filter (m: m.appName != member.appName) members
    );

  # Restricted VMs: the user's session can't supply the app's environment.
  # Anything it names in the guest is reachable, the store included (the user
  # can add to it), so GTK_PATH, QT_PLUGIN_PATH, GIO_EXTRA_MODULES and the like
  # would load the user's code into the app. Root writes this file at prep from
  # root-owned profiles only (the system's and the user's NixOS profile) plus the
  # host's static session variables; `forcedCommand` reads it.
  sessionVars = config.environment.sessionVariables;
  staticSessionVars = lib.filterAttrs (
    n: v:
    lib.elem n [
      "GIO_EXTRA_MODULES"
      "GDK_PIXBUF_MODULE_FILE"
      "GTK_A11Y"
      "NO_AT_BRIDGE"
    ]
    && lib.isString v
    && !(lib.hasInfix "$" v)
  ) sessionVars;
  restrictedEnvFile = pkgs.writeText "${unit}-launch.env" (
    lib.concatMapStrings (l: l + "\n") (
      fixedEnv
      ++ lib.optionals gui guiDefaults
      ++ lib.mapAttrsToList (n: v: "${n}=${v}") staticSessionVars
      ++ [ "LANG=${config.i18n.defaultLocale}" ]
    )
  );
  # VAR suffix… pairs: each suffix under each trusted profile, user's first.
  profileVars = {
    XDG_CONFIG_DIRS = [ "/etc/xdg" ];
    GTK_PATH = config.environment.profileRelativeSessionVariables.GTK_PATH or [ ];
    XCURSOR_PATH = [
      "/share/icons"
      "/share/pixmaps"
    ];
    QT_PLUGIN_PATH = [ "/lib/qt-6/plugins" ];
    QML2_IMPORT_PATH = [ "/lib/qt-6/qml" ];
  };
  staticDataDirs = sessionVars.XDG_DATA_DIRS or "";
  writeRestrictedEnv = ''
    hostsw="$(${co}/readlink -f /run/current-system/sw)"
    userprof="$(${co}/readlink -f /etc/profiles/per-user/${username} 2>/dev/null || true)"
    profs=()
    if [ -n "$userprof" ]; then profs+=("$userprof"); fi
    profs+=("$hostsw")
    under() {
      local out="" p s
      for s in "$@"; do for p in "''${profs[@]}"; do out="''${out:+$out:}$p$s"; done; done
      printf '%s' "$out"
    }
    {
      printf 'SBX_HOSTSW=%s\n' "$hostsw"
      printf 'XDG_DATA_DIRS=%s\n' "${
        lib.optionalString (
          staticDataDirs != "" && !(lib.hasInfix "$" staticDataDirs)
        ) "${staticDataDirs}:"
      }$(under /share)"
      ${lib.concatStrings (
        lib.mapAttrsToList (
          n: sufs: ''
            printf '${n}=%s\n' "$(under ${lib.escapeShellArgs sufs})"
          ''
        ) profileVars
      )}
      fc="$(${co}/readlink -f /etc/fonts/fonts.conf 2>/dev/null || true)"
      if [ -n "$fc" ]; then printf 'FONTCONFIG_FILE=%s\n' "$fc"; fi
      ${co}/cat ${restrictedEnvFile}
    } > "$rt/meta/launch.env"
  '';
  # The restricted key's forced command (sshd runs it for every login with that
  # key; the client's command line arrives as SSH_ORIGINAL_COMMAND): "ready"
  # (the launcher's readiness check) or "run <member>". The member starts in ~
  # with no arguments, as the dedicated container backend starts it.
  forcedCommand = pkgs.writeShellScript "${unit}-forced-command" ''
    set -euo pipefail
    case "''${SSH_ORIGINAL_COMMAND-}" in
      ready) exec ${pkgs.bash}/bin/bash -c ${lib.escapeShellArg (if guestReady != "" then guestReady else "true")} ;;
      ${lib.concatMapStrings (m: ''
        ${lib.escapeShellArg "run ${m.bin}"}) path=${lib.escapeShellArg (memberPath m)}; exe=${m.package}/bin/${m.bin} ;;
      '') members}
      *) echo "sandbox-vm: this VM only starts ${lib.concatMapStringsSep ", " (m: m.bin) members}" >&2; exit 1 ;;
    esac
    envs=()
    hostsw=""
    while IFS= read -r line; do
      case "$line" in
        SBX_HOSTSW=*) hostsw="''${line#*=}" ;;
        [A-Za-z_]*=*) envs+=("$line") ;;
      esac
    done < /run/sbx/launch.env
    # Only LANG, LC_* and COLORTERM come through sshd (AcceptEnv); LANG is set below.
    for v in ''${!LC_@}; do unset "$v"; done
    cd "$HOME"
    exec env "PATH=$path/run/current-system/sw/bin''${hostsw:+:$hostsw/bin}" "''${envs[@]}" "$exe"
  '';

  # ── Scripts ──────────────────────────────────────────────────────────────────
  # Root: fresh per-launch runtime dir with this VM's SSH keys (guest host key +
  # the user's client key, both new on every VM start) and, for per-project VMs,
  # the project path for the guest. Everything is created in root-owned parents,
  # so the user can't pre-plant anything the root steps would follow.
  prepScript = pkgs.writeShellScript "${unit}-prep" ''
    set -euo pipefail
    dir="''${1:-}"
    case "$dir" in "" | /*) ;; *) echo "${unit}: bad project path" >&2; exit 1 ;; esac
    ${idPrelude}
    umask 077
    ${co}/install -d -m 0711 /run/sandbox-vm ${base}
    ${co}/install -d -m 0755 ${
      lib.concatStringsSep " " (
        [ tree ]
        ++ map (t: "${tree}/${t}") tiers
        ++ lib.optional (binds != [ ]) "${tree}/binds"
        ++ lib.optional perCwd cwdMount
      )
    }
    ${co}/rm -rf -- "$rt"
    ${co}/install -d -m 0711 "$rt"
    ${co}/install -d -m 0700 -o ${principal} -g ${principalGroup} "$rt/meta" "$rt/ctl" "$rt/net"
    ${co}/install -d -m 0700 -o ${username} -g ${hostUser.group} "$rt/client"
    ${lib.optionalString gui ''
      # The display socket: made by the user's security-context helper (the -wl
      # unit), used by the GPU unit (the principal; ACL-granted when it differs).
      ${co}/install -d -m 0711 -o ${username} -g ${hostUser.group} "$rt/wl"
    ''}
    ${lib.optionalString gpuDevice ''
      ${co}/install -d -m 0700 -o ${gpuUser} -g ${gpuGroup} "$rt/gpu"
    ''}
    ${lib.optionalString bus ''
      ${co}/install -d -m 0700 -o ${username} -g ${hostUser.group} "$rt/bus"
      ${lib.optionalString restricted ''
        # The relay runs as ${principal}: traverse only. Each socket in here is
        # granted to it once it exists (grantBusSocket).
        ${pkgs.acl}/bin/setfacl -m "u:${principal}:--x" "$rt/bus"
      ''}
    ''}
    ${lib.optionalString capture ''
      ${co}/install -d -m 0711 -o ${captureUserName} -g ${captureUserName} "$rt/capture"
    ''}
    ${lib.optionalString grants ''
      ${co}/install -d -m 0700 -o ${username} -g ${hostUser.group} "$rt/grants"
    ''}
    ${lib.optionalString docs ''
      ${co}/install -d -m 0711 -o ${username} -g ${hostUser.group} "$rt/docs"
    ''}
    ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "${unit}" -f "$rt/meta/ssh_host_ed25519_key"
    ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "${username}@${unit}" -f "$rt/client/id_ed25519"
    ${
      if restricted then
        ''
          printf 'restrict,pty,command="%s" %s\n' ${forcedCommand} "$(${co}/cat "$rt/client/id_ed25519.pub")" > "$rt/meta/authorized_keys"
          ${writeRestrictedEnv}
        ''
      else
        ''
          ${co}/install -m 0644 "$rt/client/id_ed25519.pub" "$rt/meta/authorized_keys"
        ''
    }
    printf 'sandbox-vm %s\n' "$(${co}/cut -d' ' -f1,2 "$rt/meta/ssh_host_ed25519_key.pub")" > "$rt/client/known_hosts"
    # Root's key into the guest (`sudo sandbox-vm root`): root-only on the host.
    ${co}/install -d -m 0700 "$rt/root"
    ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "root@${unit}" -f "$rt/root/id_ed25519"
    ${co}/install -m 0644 "$rt/root/id_ed25519.pub" "$rt/meta/root_authorized_keys"
    ${co}/cp "$rt/client/known_hosts" "$rt/root/known_hosts"
    if [ -n "$dir" ]; then printf '%s' "$dir" > "$rt/meta/cwd"; fi
    printf '%s' "$cid" > "$rt/meta/cid"
    ${co}/chown ${principal}:${principalGroup} "$rt/meta"/*
    ${co}/chown ${username}:${hostUser.group} "$rt/client"/*
  '';

  cleanupScript = pkgs.writeShellScript "${unit}-cleanup" ''
    set -euo pipefail
    dir="''${1:-}"
    ${idPrelude}
    ${co}/rm -rf -- "$rt"
  '';

  # Principal: the VMM. crosvm keeps its own sandbox on (per-device minijail
  # processes with seccomp, user/pid/mount/net namespaces).
  inherit (core) fsCommon;
  guestKernelParams =
    guest.boot.kernelParams
    ++ [
      "init=${guest.system.build.toplevel}/init"
      "sbx.spec=${spec}"
    ]
    # crosvm's GPU device always gives cross-domain VMs a display on the same
    # Wayland socket (its `hidden` is honoured on Windows only), and opens it as
    # a host window, titled "crosvm", once the guest scans anything out: the
    # kernel's framebuffer console does, at boot. Cross-domain Wayland doesn't
    # use the display, so the guest's connector is disabled and nothing is.
    ++ lib.optional crossDomain "video=Virtual-1:d"
    ++ lib.optionals gameTuning [
      "transparent_hugepage=always"
      "modules_load=ntsync"
    ];
  # What the launcher waits for in the guest before running the app: sshd,
  # then the session bus and the Wayland socket the app will use (a GUI app
  # started before the proxy's socket exists has no display at all).
  guestReady = lib.concatStringsSep " && " (
    lib.optional bus "test -S ${guestSockets.dbus}"
    ++ lib.optional gui "test -S ${
      if lib.hasPrefix "/" guestWaylandDisplay then
        guestWaylandDisplay
      else
        "${guestRuntimeDir}/${guestWaylandDisplay}"
    }"
  );
  runScript = pkgs.writeShellScript "${unit}-run" ''
    set -euo pipefail
    ${core.hardening.vsockNsCheck}
    dir="''${1:-}"
    ${idPrelude}
    eu="$(${co}/id -u)"
    eg="$(${co}/id -g)"
    # Writable shares: the guest user (uid ${guestUid}) is this VMM's uid on the host.
    rw="${fsCommon}:cache=auto:uid=${guestUid}:gid=${guestGid}:uidmap=${guestUid} $eu 1:gidmap=${guestGid} $eg 1"
    pre=()
    args=(
      run
      --name ${lib.escapeShellArg "sbx-${name}"}
      --mem size=${toString memory}
      --cpus num-cores=${toString vcpus}
      ${lib.optionalString (!camera) "--no-usb"}
      ${if prefault then "--prefault-memory" else "--balloon-page-reporting"}
      --serial type=stdout,hardware=serial,console=true
      --vsock "cid=$cid"
      -s "$rt/ctl/crosvm.sock"
      --shared-dir "${core.storeShare}"
      --shared-dir "$rt/meta:sbx-meta:${fsCommon}:cache=never"
    )
    ${lib.concatMapStrings (t: ''
      args+=(--shared-dir "${tree}/${t}:sbx-${t}:$rw")
    '') tiers}
    ${lib.optionalString (binds != [ ]) ''
      args+=(--shared-dir "${tree}/binds:sbx-binds:$rw")
    ''}
    ${lib.optionalString perCwd ''
      args+=(--shared-dir "${cwdMount}:sbx-cwd:$rw")
    ''}
    ${lib.optionalString network' ''
      for _ in $(${co}/seq 1 200); do [ -S "$rt/net/passt.sock" ] && break; ${co}/sleep 0.05; done
      if [ ! -S "$rt/net/passt.sock" ]; then
        echo "${unit}: passt never created its socket; see the journal of the matching ${unit}-net unit" >&2
        exit 1
      fi
      args+=(--vhost-user "type=net,socket=$rt/net/passt.sock")
    ''}
    ${lib.optionalString gpuDevice ''
      for _ in $(${co}/seq 1 200); do [ -S "$rt/gpu/gpu.sock" ] && break; ${co}/sleep 0.05; done
      if [ ! -S "$rt/gpu/gpu.sock" ]; then
        echo "${unit}: the GPU backend never created its socket; see the journal of the matching ${unit}-gpu unit" >&2
        exit 1
      fi
    ''}
    ${lib.optionalString grants ''
      for _ in $(${co}/seq 1 200); do [ -S "$rt/grants/fs.sock" ] && break; ${co}/sleep 0.05; done
      if [ ! -S "$rt/grants/fs.sock" ]; then
        echo "${unit}: the grants share never came up; see the journal of the matching ${unit}-grantsfs unit" >&2
        exit 1
      fi
      args+=(--vhost-user "type=fs,socket=$rt/grants/fs.sock")
    ''}
    ${lib.optionalString docs ''
      for _ in $(${co}/seq 1 200); do [ -S "$rt/docs/fs.sock" ] && break; ${co}/sleep 0.05; done
      if [ -S "$rt/docs/fs.sock" ]; then
        args+=(--vhost-user "type=fs,socket=$rt/docs/fs.sock")
      else
        echo "${unit}: no document portal share (file choosers won't work); see the matching ${unit}-docs unit" >&2
      fi
    ''}
    ${lib.optionalString nvgpu ''
      args+=(--vhost-user "type=nvgpu,socket=$rt/gpu/gpu.sock,max-queue-size=256" --no-pci-hotplug-port)
    ''}
    ${lib.optionalString crossDomain ''
      args+=(--vhost-user "type=gpu,socket=$rt/gpu/gpu.sock")
    ''}
    for p in ${lib.escapeShellArgs guestKernelParams}; do args+=(-p "$p"); done
    ${lib.optionalString gameTuning ''
      # The VMM's own cookie, shared with the backend by ExecStartPost.
      args+=(--core-scheduling=false)
      aff="$(${vmHost.nvgpu.pinLayout} ${toString vcpus} smt 2>&1 | ${pkgs.gnused}/bin/sed -n 's/^  --cpu-affinity //p')" || aff=
      if [ -n "$aff" ]; then
        args+=(--cpu-affinity "$aff")
      else
        echo "${unit}: no smt vCPU layout for ${toString vcpus} vCPUs on this host; running unpinned" >&2
      fi
      pre=(${pkgs.util-linux}/bin/chrt --other --sched-runtime 100000 0
        ${pkgs.util-linux}/bin/coresched new --)
    ''}
    exec ''${pre[@]+"''${pre[@]}"} ${crosvm} "''${args[@]}" \
      --initrd ${guest.system.build.initialRamdisk}/${guest.system.boot.loader.initrdFile} \
      ${guest.boot.kernelPackages.kernel}/${guest.system.boot.loader.kernelFile}
  '';

  # Games (gameTuning): as root, once the VMM holds the cookie `coresched new`
  # made for it, give the backend's whole thread group the same one (the fork's
  # contrib/systemd/nvgpu-vmm-exec `join`). Until then, or if this fails, the
  # backend has none: it may share a core with anything, as without the
  # setting, and the guest never runs outside the VMM's cookie.
  coreschedJoin = pkgs.writeShellScript "${unit}-coresched" ''
    set -u
    backendUnit="$1" vmm="$2"
    PATH=${
      lib.makeBinPath [
        pkgs.util-linux
        pkgs.coreutils
        pkgs.systemd
      ]
    }
    cookie() { c="$(coresched get -s "$1" 2>/dev/null)" || return 0; echo "''${c##* }"; }
    be="$(systemctl show -P MainPID "$backendUnit")"
    if [ -z "$be" ] || [ "$be" = 0 ]; then
      echo "${unit}: $backendUnit has no main process; the backend keeps no core-scheduling cookie" >&2
      exit 0
    fi
    for _ in $(seq 1 200); do
      c="$(cookie "$vmm")"
      if [ -n "$c" ] && [ "$c" != 0x0 ]; then
        if coresched copy -s "$vmm" -d "$be" -t tgid && [ "$(cookie "$be")" = "$c" ]; then
          echo "${unit}: the backend (pid $be) shares the VMM's core-scheduling cookie $c"
        else
          echo "${unit}: could not give the backend (pid $be) the VMM's core-scheduling cookie" >&2
        fi
        exit 0
      fi
      kill -0 "$vmm" 2>/dev/null || exit 0
      sleep 0.05
    done
    echo "${unit}: the VMM (pid $vmm) has no core-scheduling cookie after 10 s" >&2
  '';

  # ACPI power button → orderly guest shutdown; systemd kills whatever remains.
  stopScript = pkgs.writeShellScript "${unit}-stop" ''
    dir="''${1:-}"
    ${idPrelude}
    exec ${crosvm} powerbtn "$rt/ctl/crosvm.sock"
  '';

  # Principal: user-mode networking for the guest (DHCP, DNS, NAT via host
  # sockets). No inbound forwarding, no route to the host's loopback.
  netScript = core.net.script {
    name = "${unit}-net";
    prelude = ''
      dir="''${1:-}"
    ''
    + idPrelude;
    socket = "$rt/net/passt.sock";
    forwardToResolved = dnsNames;
    inherit (vmHost) dns;
  };

  # The user: a wp_security_context_v1 socket on the user's compositor for this
  # VM's windows (see wayland-security-context.py), held for the VM's lifetime.
  # Never the raw compositor socket: sandboxed clients only see Hyprland's
  # allowlist of ordinary globals (no screencopy, data-control, virtual input…).
  wlScript = pkgs.writeShellScript "${unit}-wl" ''
    set -euo pipefail
    dir="''${1:-}"
    ${idPrelude}
    sock="$rt/wl/wayland.sock"
    ${wlSecure}/bin/wayland-security-context hold "$sock" ${lib.escapeShellArg busInstance} &
    pid=$!
    for _ in $(${co}/seq 1 100); do
      [ -S "$sock" ] && break
      kill -0 "$pid" 2>/dev/null || break
      ${co}/sleep 0.05
    done
    if [ ! -S "$sock" ]; then
      echo "${unit}: no security-context Wayland socket (is the compositor running?)" >&2
      exit 1
    fi
    ${lib.optionalString (gpuUser != username) ''
      ${pkgs.acl}/bin/setfacl -m "u:${gpuUser}:rw" "$sock"
    ''}
    wait "$pid"
  '';

  # Principal: the VM's GPU device, over vhost-user.
  #   nvgpu:        virtio-nvgpu's backend (its own sandbox: network namespace,
  #                 Landlock, seccomp), which is also the host half of the Wayland
  #                 proxy. Compute (CUDA) only when a member has the gpu capability.
  #   cross-domain: crosvm's GPU device as a separate process, cross-domain
  #                 Wayland only (no virgl/venus: no host GPU API at all), its
  #                 virtual display hidden so no stray window appears.
  waitForWl = ''
    for _ in $(${co}/seq 1 200); do [ -S "$rt/wl/wayland.sock" ] && break; ${co}/sleep 0.05; done
  '';
  gpuScript = pkgs.writeShellScript "${unit}-gpu" (
    ''
      set -euo pipefail
      dir="''${1:-}"
      ${idPrelude}
      ${lib.optionalString gui waitForWl}
    ''
    + (
      if nvgpu then
        ''
          exec ${vmHost.nvgpu.backend}/bin/vhost-user-nvgpu --socket "$rt/gpu/gpu.sock" ${lib.optionalString gui ''--wayland-socket "$rt/wl/wayland.sock"''} ${lib.optionalString gpuCap "--allow-compute"} ${lib.escapeShellArgs nvgpuWindowArgs} ${lib.optionalString capture ''--inject-socket "$rt/gpu/inject.sock" --inject-uid "$(${co}/id -u ${captureUserName})"''}
        ''
      else
        ''
          exec ${pkgs.crosvm}/bin/crosvm device gpu --socket-path "$rt/gpu/gpu.sock" \
            --wayland-sock "$rt/wl/wayland.sock" \
            --params ${
              lib.escapeShellArg (
                builtins.toJSON {
                  context-types = "cross-domain";
                  displays = [ { hidden = true; } ];
                }
              )
            }
        ''
    )
  );

  # The user: the grants share, the user's whole home behind crosvm's dynamic
  # path allowlist, which starts empty (the guest sees nothing through it until
  # a folder is granted). Jailed like crosvm's other devices (user/pid/mount/net
  # namespaces, pivot_root into the home, seccomp).
  grantsFsScript = pkgs.writeShellScript "${unit}-grantsfs" ''
    set -euo pipefail
    dir="''${1:-}"
    ${idPrelude}
    eu="$(${co}/id -u)"
    eg="$(${co}/id -g)"
    ${co}/rm -f "$rt/grants/fs.sock" "$rt/grants/allow.sock"
    exec ${crosvmFs}/bin/crosvm device fs \
      --socket-path "$rt/grants/fs.sock" \
      --allowlist-socket-path "$rt/grants/allow.sock" \
      --tag sbx-grants \
      --shared-dir ${home} \
      --cfg cache=auto,timeout=1,negative_timeout=0,posix_acl=false,security_ctx=false \
      --uid "$eu" --gid "$eg" \
      --uid-map "$eu $eu 1" --gid-map "$eg $eg 1"
  '';

  # The user: takes grant requests (from the launchers and the broker) and has
  # the guest agent mount what the allowlist now lets through.
  grantsHubScript = pkgs.writeShellScript "${unit}-grants" ''
    set -euo pipefail
    dir="''${1:-}"
    ${idPrelude}
    for _ in $(${co}/seq 1 200); do [ -S "$rt/grants/allow.sock" ] && break; ${co}/sleep 0.05; done
    exec ${grantsPkg}/bin/sbx-grants hub --home ${home} --dir "$rt/grants"
  '';

  # Documents: the document portal's by-app view for this VM's flatpak identity,
  # over virtio-fs. Two units, so the one that serves the guest holds nothing of
  # the user's but that view:
  #   -docs-portal (the user): activates the portal (D-Bus activated) and waits
  #     for the view, with the session bus;
  #   -docs (the user): crosvm's jailed fs device on that view alone, bound in by
  #     systemd as root (the portal's FUSE is allow_other:
  #     overlays/custom-packages.nix). No runtime dir, home, session bus or host
  #     network namespace (abstract sockets), so escaping crosvm's jail reaches
  #     none of them. It stays the user's uid: the portal reports its own uid as
  #     every file's owner, and the guest kernel checks permissions against what
  #     the device reports (virtio-fs default_permissions); a device in another
  #     uid's user namespace could only show those files as nobody's.
  docsView = "${base}/docs-view";
  docsSource = "${hostRuntimeDir}/doc/by-app/${busAppId}";
  docsPortalScript = pkgs.writeShellScript "${unit}-docs-portal" ''
    set -euo pipefail
    SYSTEMD_LOG_TARGET=console SYSTEMD_LOG_LEVEL=debug \
      ${pkgs.systemd}/bin/busctl --user call org.freedesktop.portal.Documents \
      /org/freedesktop/portal/documents org.freedesktop.portal.Documents GetMountPoint >/dev/null
    for _ in $(${co}/seq 1 100); do [ -d ${lib.escapeShellArg docsSource} ] && exit 0; ${co}/sleep 0.05; done
    echo "${unit}-docs-portal: document portal view missing after 5 s: ${docsSource}" >&2
    exit 1
  '';
  docsScript = pkgs.writeShellScript "${unit}-docs" ''
    set -Eeuo pipefail
    stage="initialization"
    trap 'rc=$?; echo "${unit}-docs: $stage failed (exit $rc, line $LINENO)" >&2; exit "$rc"' ERR
    dir="''${1:-}"
    ${idPrelude}
    eu="$(${co}/id -u)"
    eg="$(${co}/id -g)"
    stage="starting the document virtio-fs backend"
    ${co}/rm -f "$rt/docs/fs.sock"
    ${pkgs.crosvm}/bin/crosvm device fs \
      --socket-path "$rt/docs/fs.sock" \
      --tag sbx-docs \
      --shared-dir ${docsView} \
      --cfg cache=never,posix_acl=false,security_ctx=false \
      --uid "$eu" --gid "$eg" \
      --uid-map "$eu $eu 1" --gid-map "$eg $eg 1" &
    pid=$!
    ${lib.optionalString (principal != username) ''
      stage="granting the VM access to the document virtio-fs socket"
      for _ in $(${co}/seq 1 200); do [ -S "$rt/docs/fs.sock" ] && break; ${co}/sleep 0.05; done
      ${pkgs.acl}/bin/setfacl -m "u:${principal}:rw" "$rt/docs/fs.sock"
    ''}
    stage="waiting for the document virtio-fs backend"
    wait "$pid"
  '';

  # Root: attach every USB video-class device (a webcam, as the host's uvcvideo
  # sees it) to the running VM, recording the xHCI ports; on stop, detach them
  # and let the host's drivers take them back.
  cameraAttach = pkgs.writeShellScript "${unit}-camera-attach" ''
    set -euo pipefail
    dir="''${1:-}"
    ${idPrelude}
    sock="$rt/ctl/crosvm.sock"
    [ -S "$sock" ] || { echo "${unit}: the VM isn't running" >&2; exit 1; }
    ${co}/install -d -m 0700 "$rt/camera"
    : > "$rt/camera/ports"
    found=0
    for d in /sys/bus/usb/devices/*; do
      name="$(${co}/basename "$d")"
      case "$name" in *:* | usb*) continue ;; esac
      [ -f "$d/busnum" ] || continue
      video=0
      for c in "$d"/"$name":*/bInterfaceClass; do
        [ "$(${co}/cat "$c" 2>/dev/null)" = 0e ] && video=1
      done
      [ "$video" = 1 ] || continue
      bus="$(${co}/cat "$d/busnum")"
      num="$(${co}/cat "$d/devnum")"
      node="$(printf '/dev/bus/usb/%03d/%03d' "$bus" "$num")"
      out="$(${crosvm} usb attach "1:1:$bus:$num" "$node" "$sock" || true)"
      case "$out" in
        "ok "*)
          echo "''${out#ok } $name" >> "$rt/camera/ports"
          found=1
          echo "attached $(${co}/cat "$d/product" 2>/dev/null || echo "$name") (xHCI port ''${out#ok })" ;;
        *) echo "could not attach $node: $out" >&2 ;;
      esac
    done
    [ "$found" = 1 ] || { echo "${unit}: no camera to attach" >&2; exit 1; }
  '';
  cameraDetach = pkgs.writeShellScript "${unit}-camera-detach" ''
    set -uo pipefail
    dir="''${1:-}"
    ${idPrelude}
    [ -f "$rt/camera/ports" ] || exit 0
    while read -r port name; do
      [ -S "$rt/ctl/crosvm.sock" ] && ${crosvm} usb detach "$port" "$rt/ctl/crosvm.sock" >/dev/null
      # Its interfaces were claimed away from the host's drivers: probe again.
      for i in /sys/bus/usb/devices/"$name":*; do
        [ -e "$i" ] && ${co}/basename "$i" > /sys/bus/usb/drivers_probe 2>/dev/null
      done
    done < "$rt/camera/ports"
    ${co}/rm -f "$rt/camera/ports"
    exit 0
  '';

  # The user (and the broker, as the user): attach or detach the cameras of the
  # running VM(s). Per-project VMs share one broker socket, so every running one.
  cameraCtl = pkgs.writeShellScript "${unit}-camera" ''
    set -uo pipefail
    action="''${1:-attach}"
    case "$action" in attach) verb=start ;; detach) verb=stop ;; *) echo "usage: attach|detach" >&2; exit 2 ;; esac
    ok=0
    ${
      if perCwd then
        ''
          while read -r u; do
            inst="''${u#${unit}@}"
            ${systemctl} "$verb" "${unit}-camera@$inst" && ok=1
          done < <(${systemctl} list-units --plain --no-legend --state=active '${unit}@*.service' | ${pkgs.gawk}/bin/awk '{print $1}')
        ''
      else
        ''
          if ${systemctl} is-active --quiet ${unit}.service; then
            ${systemctl} "$verb" ${unit}-camera.service && ok=1
          fi
        ''
    }
    [ "$ok" = 1 ] || { echo "${label} isn't running, or its camera couldn't be ''${action}ed" >&2; exit 1; }
  '';

  # For the broker (grant-path PATH rw|ro). Per-project VMs share one broker
  # socket, so the folder goes to every running one of them.
  grantPathsScript = pkgs.writeShellScript "${unit}-grant-path" ''
    set -uo pipefail
    ok=0
    grant() {
      ${idPrelude}
      if ${grantsPkg}/bin/sbx-grants request "$rt/grants" "$path" "$mode"; then ok=1; fi
    }
    path="$1"
    mode="''${2:-rw}"
    ${
      if perCwd then
        ''
          while read -r u; do
            inst="''${u#${unit}-grants@}"
            dir="$(${pkgs.systemd}/bin/systemd-escape --unescape --path -- "''${inst%.service}")"
            grant
          done < <(${systemctl} list-units --plain --no-legend --state=active '${unit}-grants@*.service' | ${pkgs.gawk}/bin/awk '{print $1}')
        ''
      else
        ''
          dir=""
          grant
        ''
    }
    if [ "$ok" != 1 ]; then echo "${label} isn't running, or the grant failed" >&2; exit 1; fi
  '';

  # Root, once the backend has bound its socket (virtio-nvgpu's
  # contrib/systemd/nvgpu-socket-open, with an ACL for the VMM's uid instead of
  # a group: the VMM's group may be the shared `users`). The directory becomes
  # root's, so the backend can no longer swap what's in it.
  gpuSocketOpen = pkgs.writeShellScript "${unit}-gpu-socket" ''
    set -eu
    dir="''${1:-}"
    ${idPrelude}
    d="$rt/gpu"
    sock="$d/gpu.sock"
    owner="$(${co}/stat -c %u -- "$d")"
    i=0
    while [ ! -S "$sock" ]; do
      i=$((i + 1))
      [ "$i" -le 100 ] || { echo "${unit}: no backend socket after 10 s" >&2; exit 1; }
      ${co}/sleep 0.1
    done
    ${co}/chown root:root -- "$d"
    ${co}/chmod 0711 -- "$d"
    [ ! -L "$sock" ] && [ -S "$sock" ] || { echo "${unit}: $sock is not a socket" >&2; exit 1; }
    [ "$(${co}/stat -c %u -- "$sock")" = "$owner" ] || { echo "${unit}: $sock is not the backend's" >&2; exit 1; }
    ${pkgs.acl}/bin/setfacl -m "u:${principal}:rw" -- "$sock"
    ${lib.optionalString capture ''
      # The inject socket: to this VM's capture helper alone.
      inj="$d/inject.sock"
      i=0
      while [ ! -S "$inj" ]; do
        i=$((i + 1))
        [ "$i" -le 100 ] || { echo "${unit}: no inject socket after 10 s" >&2; exit 1; }
        ${co}/sleep 0.1
      done
      [ ! -L "$inj" ] && [ "$(${co}/stat -c %u -- "$inj")" = "$owner" ] || { echo "${unit}: $inj is not the backend's" >&2; exit 1; }
      ${pkgs.acl}/bin/setfacl -m "u:${captureUserName}:rw" -- "$inj"
    ''}
  '';

  # Host-GPU device nodes for the virtio-nvgpu backend: the host's
  # modules.sandbox.gpuDevices narrowing when set (multi-GPU hosts), else every
  # NVIDIA and DRM node.
  nvgpuDeviceAllow =
    (
      if config.modules.sandbox.gpuDevices != null then
        map (d: if d == "/dev/dri" then "char-drm rw" else "${d} rw") config.modules.sandbox.gpuDevices
      else
        [
          # Match /proc/devices: open NVIDIA drivers register major 195 as
          # "nvidia". Keep the frontend name for drivers that use it; allowing
          # only that name leaves /dev/nvidia0 denied by DevicePolicy=closed.
          "char-nvidia rw"
          "char-nvidia-frontend rw"
          "char-drm rw"
        ]
    )
    ++ [
      "/dev/nvidiactl rw"
      "/dev/nvidia-modeset rw"
      "/dev/udmabuf rw"
    ]
    ++ lib.optional gpuCap "/dev/nvidia-uvm rw";

  # Restricted VMs: give the relay's uid (the principal) one of the user's
  # proxy sockets in $rt/bus, once the proxy has made it. ExecStartPost of the
  # proxy's unit, as the user who owns the socket; the relay starts after it.
  # (Restricted VMs are never per-project, so there's no instance path.)
  grantBusSocket = pkgs.writeShellScript "${unit}-grant-bus-socket" ''
    set -euo pipefail
    dir=""
    ${idPrelude}
    sock="$rt/bus/$1"
    for _ in $(${co}/seq 1 200); do [ -S "$sock" ] && break; ${co}/sleep 0.05; done
    if [ ! -S "$sock" ] || [ -L "$sock" ]; then
      echo "${unit}: no socket $sock to grant" >&2
      exit 1
    fi
    ${pkgs.acl}/bin/setfacl -m "u:${principal}:rw" -- "$sock"
  '';

  # Where the relay finds the broker's sockets for this VM. A relay running as
  # the user reaches them in the user's runtime dir; one running as the
  # principal (restricted) can't traverse that, so systemd binds the two sockets
  # into its unit (relayService), and the broker ACLs them for the principal
  # (brokerEntry.uid).
  relayBrokerSocks =
    if restricted then
      {
        pulse = "${base}/relay/pulse";
        broker = "${base}/relay/broker";
      }
    else
      {
        pulse = "${hostRuntimeDir}/sbx-broker/${brokerName}.pulse";
        broker = "${hostRuntimeDir}/sbx-broker/${brokerName}.sock";
      };

  # This VM's end of the vsock relay, on port = its CID, answering only that
  # CID, and only for the services it was given. Runs as the user, or as the
  # principal in a restricted VM (so nothing that parses the guest's traffic
  # runs as the user there).
  relayScript = pkgs.writeShellScript "${unit}-relay" ''
    set -euo pipefail
    dir="''${1:-}"
    ${idPrelude}
    exec ${vsockRelay}/bin/vsock-relay host --cid "$cid" ${
      lib.concatStringsSep " " (
        lib.optional audio "pulse=${
          if broker then relayBrokerSocks.pulse else "${hostRuntimeDir}/pulse/native"
        }"
        ++ lib.optional (bus && !capture) ''dbus="$rt/bus/bus.sock"''
        ++ lib.optional (bus && capture) ''capture-dbus="$rt/bus/capture.sock"''
        ++ lib.optional broker "broker=${relayBrokerSocks.broker}"
        ++ lib.optional grants ''grants="$rt/grants/guest.sock"''
        ++ lib.mapAttrsToList (n: r: lib.escapeShellArg "${n}=${r.host}") extraRelays
      )
    }
  '';

  # The user: the VM's session bus, filtered by the members' own policy. Wrapped
  # in a minimal bwrap only to give the proxy a /.flatpak-info at its /proc/root,
  # which is where the portals read a caller's identity from.
  busScript = pkgs.writeShellScript "${unit}-bus" ''
    set -euo pipefail
    dir="''${1:-}"
    ${idPrelude}
    # The portal looks up the flatpak instance named in .flatpak-info here.
    ${co}/mkdir -p "${hostRuntimeDir}/.flatpak/${busInstance}"
    printf '{"child-pid": 1, "mnt-namespace": 1, "net-namespace": 1, "pid-namespace": 1}' \
      > "${hostRuntimeDir}/.flatpak/${busInstance}/bwrapinfo.json"
    ${co}/rm -f "$rt/bus/bus.sock"
    exec ${pkgs.bubblewrap}/bin/bwrap \
      --ro-bind-try /etc /etc \
      --ro-bind /nix/store /nix/store \
      --bind /run /run \
      --ro-bind ${busFlatpakInfo} /.flatpak-info \
      --die-with-parent \
      -- ${pkgs.xdg-dbus-proxy}/bin/xdg-dbus-proxy "$DBUS_SESSION_BUS_ADDRESS" "$rt/bus/bus.sock" \
        ${lib.concatMapStringsSep " " lib.escapeShellArg busArgs}
  '';

  # Screen capture (capture VMs), two units so no uid holds both halves:
  #   -capture-bus, the user: between the relay and the -bus proxy, answers the
  #     guest's ScreenCast calls and, after the portal's own consent dialog,
  #     takes the restricted PipeWire remote and hands it to the broker. It
  #     parses what the guest sends, so it is confined like the relay.
  #   -capture-broker, sbx-cap-<vm>: the only uid the backend's inject socket
  #     serves; consumes that remote and injects its buffers. It takes requests
  #     from the user's uid alone (SO_PEERCRED), never from the guest.
  # The capture worker's host GPU: EGL's modifier query on the render node it
  # opens (--render-node, /dev/dri/renderD128 by default) and the NVIDIA nodes
  # behind it (major 195: nvidia*, nvidiactl, nvidia-modeset). No card nodes,
  # udmabuf or UVM, which only the backend needs; injection itself is the
  # backend's socket.
  captureDeviceAllow = [
    "char-nvidia rw"
    "char-nvidia-frontend rw"
    "/dev/dri/renderD128 rw"
  ];
  captureBrokerScript = pkgs.writeShellScript "${unit}-capture-broker" ''
    set -euo pipefail
    dir="''${1:-}"
    ${idPrelude}
    ${co}/rm -f "$rt/capture/broker.sock"
    exec ${vmHost.dbusProxy}/bin/vm-capture-broker --role host \
      --listen "$rt/capture/broker.sock" --allowed-uid ${toString hostUser.uid} \
      --worker ${vmHost.dbusProxy}/bin/vm-capture --inject-socket "$rt/gpu/inject.sock"
  '';
  captureBusScript = pkgs.writeShellScript "${unit}-capture-bus" ''
    set -euo pipefail
    dir="''${1:-}"
    ${idPrelude}
    ${co}/rm -f "$rt/bus/capture.sock"
    exec ${vmHost.dbusProxy}/bin/vm-dbus-capture-proxy --role host \
      --listen "$rt/bus/capture.sock" --upstream "$rt/bus/bus.sock" \
      --broker "$rt/capture/broker.sock"
  '';

  # ── Launchers ────────────────────────────────────────────────────────────────
  # A member's command: run it in the VM (starting the VM if needed) over vsock SSH.
  launcherFor =
    member:
    pkgs.writeShellScript "${unit}-launch-${member.bin}" ''
      set -euo pipefail
      ${
        if perCwd then
          ''
            dir="$(pwd -P)"
            # The path travels through a unit instance name, a systemd ExecStart line
            # and the guest, so only plain path characters are accepted.
            case "$dir" in
              /)
                echo "${member.bin}: sandbox-vm won't attach / (the whole host filesystem) as a project" >&2
                exit 1 ;;
              *[!A-Za-z0-9._/@+,=~\ -]*)
                echo "${member.bin}: sandbox-vm can't attach '$dir' (supported path characters: A-Z a-z 0-9 . _ / @ + , = ~ - and space)" >&2
                exit 1 ;;
            esac
            unit="${unit}@$(${pkgs.systemd}/bin/systemd-escape --path -- "$dir").service"
            workdir="$dir"
          ''
        else
          ''
            dir=""
            unit="${unit}.service"
            workdir=${home}
            here="$(pwd -P)"
            grantHere=0
            ${lib.optionalString (projectDirs != [ ] || grantCwd') ''
              # Start in $PWD when it's inside one of the instance's projects, or
              # (grantCwd) anywhere in ~: running the app there grants the VM that folder.
              for p in ${lib.escapeShellArgs projectDirs}; do
                case "$here/" in "$p"/*) workdir="$here" ;; esac
              done
              if [ "$workdir" = ${home} ] && [ "$here" != ${home} ]; then
                ${
                  if grantCwd' then
                    ''
                      case "$here" in
                        ${home}/*) workdir="$here"; grantHere=1 ;;
                        *) echo "${member.bin}: $here is outside ~ and not shared with ${label}; starting in ~" >&2 ;;
                      esac
                    ''
                  else
                    ''
                      echo "${member.bin}: $here isn't shared with ${label}; starting in ~ (projects: ${lib.concatStringsSep ", " projectDirs})" >&2
                    ''
                }
              fi
            ''}
          ''
      }
      ${idPrelude}

      # Session accounting: every launcher holds a shared lock for its lifetime; the
      # one that can upgrade it to exclusive on the way out is the last, and stops
      # the VM (unless the instance is persistent).
      lockdir="''${XDG_RUNTIME_DIR:-/run/user/$(${co}/id -u)}/sandbox-vm"
      ${co}/mkdir -p -m 0700 "$lockdir"
      exec 9>"$lockdir/${name}-$id.lock"
      ${flock} -s 9
      finish() {
        ${
          if persistent then
            "exit \"$1\""
          else
            ''
              ${flock} -u 9
              if ${flock} -xn 9; then ${systemctl} stop "$unit" >/dev/null 2>&1 || true; fi
              exit "$1"
            ''
        }
      }

      if ! ${systemctl} start "$unit"; then
        echo "${member.bin}: could not start $unit (see: journalctl -u '$unit')" >&2
        finish 1
      fi

      ssh_opts=(
        -F /dev/null
        -o "ProxyCommand=${pkgs.systemd}/lib/systemd/systemd-ssh-proxy %h %p"
        -o ProxyUseFdpass=yes
        -o User=${username}
        -o IdentityFile="$rt/client/id_ed25519"
        -o IdentitiesOnly=yes
        -o UserKnownHostsFile="$rt/client/known_hosts"
        -o GlobalKnownHostsFile=/dev/null
        -o HostKeyAlias=sandbox-vm
        -o StrictHostKeyChecking=yes
        -o CheckHostIP=no
        -o BatchMode=yes
        -o LogLevel=ERROR
        -o ForwardAgent=no
        -o ForwardX11=no
        -o ClearAllForwardings=yes
        -o PermitLocalCommand=no
        -o EscapeChar=none
        -o ServerAliveInterval=15
      )
      envs=()
      [ -n "''${LANG:-}" ] && envs+=("LANG=$LANG")
      [ -n "''${COLORTERM:-}" ] && envs+=("COLORTERM=$COLORTERM")
      if [ "''${#envs[@]}" -gt 0 ]; then ssh_opts+=(-o "SetEnv=''${envs[*]}"); fi

      # Wait for the guest's sshd (the unit is up once its keys exist).
      up=0
      for _ in $(${co}/seq 1 240); do
        if ${ssh} "''${ssh_opts[@]}" -o ConnectTimeout=2 -T -- "vsock/$cid" ${
          if restricted then
            "ready"
          else if guestReady != "" then
            lib.escapeShellArg guestReady
          else
            "true"
        } 2>/dev/null; then
          up=1
          break
        fi
        ${systemctl} is-active --quiet "$unit" || break
        ${co}/sleep 0.25
      done
      if [ "$up" != 1 ]; then
        echo "${member.bin}: the VM did not come up${
          lib.optionalString (guestReady != "")
            ", or its bus/display never appeared: in the guest, journalctl -u sbx-setup -u sbx-dbus-proxy -u 'sbx-wayland-*'"
        } (see: journalctl -u '$unit')" >&2
        finish 1
      fi
      ${lib.optionalString (member.caps.camera && broker && member.cameraOnLaunch or false) ''
        # The camera, if you allow it (asked in the background, so the app
        # starts meanwhile), unless it's already attached.
        camunit="''${unit%%@*}"; camunit="''${camunit%.service}-camera"
        case "$unit" in *@*) camunit="$camunit@''${unit#*@}" ;; *) camunit="$camunit.service" ;; esac
        if ! ${systemctl} is-active --quiet "$camunit"; then
          SBX_BROKER="''${XDG_RUNTIME_DIR:-/run/user/$(${co}/id -u)}/sbx-broker/${brokerName}.sock" \
            ${sbxRequest}/bin/sbx-request camera --reason "${member.appName} was started" >/dev/null 2>&1 &
        fi
      ''}
      ${lib.optionalString (!perCwd && grantCwd') ''
        if [ "$grantHere" = 1 ] && ! ${grantsPkg}/bin/sbx-grants request "$rt/grants" "$here" rw; then
          echo "${member.bin}: couldn't give ${label} $here; starting in ~" >&2
          workdir=${home}
        fi
      ''}

      # The guest boots from the host store, so the host's system profile (for the
      # usual CLI tools) is on the guest PATH after the members themselves (so they
      # can run each other).
      hostsw="$(${co}/readlink -f /run/current-system/sw)"
      genv=("PATH=${memberPath member}/run/current-system/sw/bin:$hostsw/bin")
      ${lib.optionalString gui ''
        # GUI session environment. Store paths are valid in the guest as-is; the
        # host's profile symlinks aren't, so they're resolved first.
        userprof="$(${co}/readlink -f /etc/profiles/per-user/${username} 2>/dev/null || true)"
        nixprof="$(${co}/readlink -f "''${HOME:-${home}}/.nix-profile" 2>/dev/null || true)"
        rewrite() {
          local v="$1"
          v="''${v//\/run\/current-system\/sw/$hostsw}"
          [ -n "$userprof" ] && v="''${v//\/etc\/profiles\/per-user\/${username}/$userprof}"
          [ -n "$nixprof" ] && v="''${v//''${HOME:-${home}}\/.nix-profile/$nixprof}"
          printf '%s' "$v"
        }
        for v in XDG_DATA_DIRS XDG_CONFIG_DIRS QT_PLUGIN_PATH QML2_IMPORT_PATH \
                 QT_QPA_PLATFORMTHEME QT_STYLE_OVERRIDE QT_QPA_PLATFORM \
                 GDK_PIXBUF_MODULE_FILE GIO_EXTRA_MODULES GTK_PATH GTK_THEME \
                 XCURSOR_THEME XCURSOR_SIZE XCURSOR_PATH HYPRCURSOR_THEME HYPRCURSOR_SIZE \
                 XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_SESSION_DESKTOP DESKTOP_SESSION \
                 NIXOS_OZONE_WL ELECTRON_OZONE_PLATFORM_HINT MOZ_ENABLE_WAYLAND GDK_BACKEND; do
          val="''${!v:-}"
          if [ -n "$val" ]; then genv+=("$v=$(rewrite "$val")"); fi
        done
        # gui.nix's defaults, for launches from outside the session environment.
        for kv in ${lib.escapeShellArgs guiDefaults}; do
          case " ''${genv[*]} " in *" ''${kv%%=*}="*) ;; *) genv+=("$kv") ;; esac
        done
        fc="$(${co}/readlink -f /etc/fonts/fonts.conf 2>/dev/null || true)"
        if [ -n "$fc" ]; then genv+=("FONTCONFIG_FILE=$fc"); fi
      ''}
      genv+=(${lib.escapeShellArgs fixedEnv})
      ${
        if restricted then
          ''
            # Restricted: the guest runs the member itself (forcedCommand), in ~,
            # with no arguments, like the dedicated container backend.
            if [ "$#" -gt 0 ]; then
              echo "${member.bin}: arguments aren't passed to ${label} (it runs as its own user)" >&2
            fi
            remote="run ${member.bin}"
          ''
        else
          ''
            remote="cd $(printf '%q' "$workdir") && exec env $(printf '%q ' "''${genv[@]}" ${member.package}/bin/${member.bin} "$@")"
          ''
      }
      tty=-T
      if [ -t 0 ] && [ -t 1 ]; then tty=-t; fi
      set +e
      ${ssh} "''${ssh_opts[@]}" "$tty" -- "vsock/$cid" "$remote"
      rc=$?
      set -e
      finish "$rc"
    '';

  # ── Units ────────────────────────────────────────────────────────────────────
  vmmDeps = [
    (ref "${unit}-prep")
  ]
  ++ lib.optional network' (ref "${unit}-net")
  ++ lib.optional gpuDevice (ref "${unit}-gpu")
  ++ lib.optional grants (ref "${unit}-grantsfs")
  # Bound before the VM starts, so nothing else can hold the relay's port.
  ++ lib.optional relay (ref "${unit}-relay");
  vmmService = {
    description = "Sandbox VM: ${label}";
    requires = vmmDeps;
    # Wanted, not required: without a document portal the VM still starts.
    wants = lib.optional docs (ref "${unit}-docs");
    after = vmmDeps ++ lib.optional docs (ref "${unit}-docs");
    # Like the systemd backend: a rebuild must not kill a running app. A changed
    # definition takes effect on the next launch.
    restartIfChanged = false;
    stopIfChanged = false;
    serviceConfig = {
      Type = "simple";
      ExecStart = "${runScript}${instArg}";
      ExecStartPost = lib.optional gameTuning "+${coreschedJoin} ${ref "${unit}-gpu"} $MAINPID";
      ExecStop = "-${stopScript}${instArg}";
      TimeoutStopSec = 20;
      KillMode = "mixed";
      Restart = "no";

      User = principal;
      Group = principalGroup;

      # A compute VM's UVM semaphore pools (virtio-nvgpu's crosvm patch 0007,
      # RegisterUvmPool) are checked resident with mincore before they get a
      # KVM slot; mincore is not in @system-service, and EPERM refuses the pool.
      SystemCallFilter = core.hardening.jailedSyscallFilter ++ lib.optional (nvgpu && gpuCap) "mincore";

      # The host filesystem is read-only and the user's data invisible, apart from
      # the members' storage/binds (BindPaths, set up by systemd as root) and the
      # runtime dir.
      InaccessiblePaths = [
        "-/persist"
        "-/large"
        "-/cache"
      ]
      # The pool check's access() goes through /proc/self/fd, not this path.
      ++ lib.optional (nvgpu && gpuCap) "-/dev/nvidia-uvm";
      BindPaths = storageBinds ++ rwBinds ++ lib.optional perCwd (bindPair "%f" cwdMount);
      BindReadOnlyPaths = roBinds;
      ReadWritePaths = [ base ];

      # A compute VM's pool check also asks whether this uid could open the
      # backend's UVM file for writing (mincore answers truthfully only then:
      # can_do_mincore), and the device cgroup is part of that answer. The node
      # is 0666 on NixOS, so no group; "w" is all access(W_OK) needs, and the
      # path itself is hidden below: the VMM checks the backend's descriptor,
      # it never opens UVM itself.
      DeviceAllow = [
        "/dev/kvm rw"
        "/dev/vhost-vsock rw"
      ]
      ++ lib.optional (nvgpu && gpuCap) "/dev/nvidia-uvm w";

      # Guest RAM, plus virtio-nvgpu's window: under crosvm it is shared
      # memory a guest kernel could fault in and charge here, up to its size
      # (the fork's DEPLOY.md, "Sizing the window").
      MemoryMax = "${toString (memory + 512 + (if nvgpu then gpuMemoryMiB else 0))}M";
    }
    # crosvm's own sandbox (namespaces, pivot_root, seccomp) and the rest of
    # the VMM's confinement (lib/vm/core/hardening.nix).
    // core.hardening.vmm;
  };

  # Helper units: started with the VM, stopped (and cleaned up) whenever it goes
  # down, however it went down.
  helper =
    attrs:
    {
      bindsTo = [ (ref unit) ];
      restartIfChanged = false;
      stopIfChanged = false;
    }
    // attrs;

  prepService = helper {
    description = "Sandbox VM keys and runtime dir: ${label}";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${prepScript}${instArg}";
      ExecStop = "${cleanupScript}${instArg}";
      PrivateNetwork = true;
      ProtectHome = true;
    };
  };

  afterPrep = extra: {
    requires = [ (ref "${unit}-prep") ] ++ extra;
    after = [ (ref "${unit}-prep") ] ++ extra;
  };

  netService = helper (
    afterPrep [ ]
    // {
      description = "Sandbox VM network (passt): ${label}";
      # The network policy (lib/netpolicy.nix; VMs default to "internet": not
      # the host, the LAN, the tailnet or container/VM bridges).
      serviceConfig = {
        ExecStart = "${netScript}${instArg}";
      }
      // core.net.serviceConfig {
        user = principal;
        group = principalGroup;
        policy = netPolicy;
        readWritePaths = [ base ];
      };
    }
  );

  wlService = helper (
    afterPrep [ ]
    // {
      description = "Sandbox VM display (Wayland security context): ${label}";
      environment = {
        XDG_RUNTIME_DIR = hostRuntimeDir;
        WAYLAND_DISPLAY = hostWaylandSocket;
      };
      serviceConfig = {
        ExecStart = "${wlScript}${instArg}";
        User = username;
        Group = hostUser.group;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectSystem = "strict";
        ReadWritePaths = [ base ];
        PrivateTmp = true;
        PrivateNetwork = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        SystemCallArchitectures = "native";
        LimitCORE = 0;
      };
    }
  );

  gpuService = helper (
    afterPrep (lib.optional gui (ref "${unit}-wl"))
    // {
      description = "Sandbox VM GPU (${if nvgpu then "virtio-nvgpu" else "cross-domain"}): ${label}";
      environment = lib.optionalAttrs nvgpu { RUST_LOG = "warn"; };
      serviceConfig = {
        ExecStart = "${gpuScript}${instArg}";
        User = gpuUser;
        Group = gpuGroup;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        ProtectSystem = "strict";
        ProtectHome = "tmpfs";
        ReadWritePaths = [ base ];
        PrivateTmp = true;
        PrivateIPC = true;
        PrivateNetwork = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_NETLINK"
        ];
        SystemCallArchitectures = "native";
        DevicePolicy = "closed";
        # cross-domain touches no host GPU at all.
        DeviceAllow = lib.optionals nvgpu nvgpuDeviceAllow;
        UMask = "0077";
        LimitCORE = 0;
      }
      # The rest of virtio-nvgpu's own unit (contrib/systemd/vhost-user-nvgpu@.service).
      // lib.optionalAttrs nvgpu {
        Type = "exec";
        ExecStartPost = "+${gpuSocketOpen}${instArg}";
        SupplementaryGroups = [
          "video"
          "render"
          "kvm"
        ];
        MemoryMax = "2G";
        MemorySwapMax = 0;
        TasksMax = 256;
        OOMScoreAdjust = 500;
        TimeoutStopSec = 10;
        MemoryDenyWriteExecute = true;
        ProtectProc = "invisible";
      };
    }
  );

  relayService = helper (
    afterPrep (
      lib.optional bus (ref "${unit}-bus")
      ++ lib.optional capture (ref "${unit}-capture-bus")
      ++ lib.optional grants (ref "${unit}-grants")
    )
    // {
      description = "Sandbox VM host services (vsock relay): ${label}";
      serviceConfig = {
        # Ready once the vsock port is bound.
        Type = "notify";
        NotifyAccess = "main";
        ExecStart = "${relayScript}${instArg}";
        User = if restricted then principal else username;
        Group = if restricted then principalGroup else hostUser.group;
        # Restricted: the broker's sockets for this VM, bound in by systemd (as
        # root) from the user's runtime dir, which the principal can't traverse.
        # Soft: absent while the broker isn't running. A bind pins the socket, so
        # a broker restart needs a VM restart (as for containers).
        BindPaths = lib.optionals (restricted && broker) (
          lib.optional audio "-${hostRuntimeDir}/sbx-broker/${brokerName}.pulse:${relayBrokerSocks.pulse}"
          ++ [ "-${hostRuntimeDir}/sbx-broker/${brokerName}.sock:${relayBrokerSocks.broker}" ]
        );
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_VSOCK"
        ];
        SystemCallArchitectures = "native";
        UMask = "0077";
        LimitCORE = 0;
      };
    }
  );

  busService = helper (
    afterPrep [ ]
    // {
      description = "Sandbox VM session bus (filtered D-Bus proxy): ${label}";
      environment = {
        XDG_RUNTIME_DIR = hostRuntimeDir;
        DBUS_SESSION_BUS_ADDRESS = "unix:path=${hostRuntimeDir}/bus";
      };
      serviceConfig = {
        ExecStart = "${busScript}${instArg}";
        ExecStartPost = lib.optional restricted "${grantBusSocket} bus.sock";
        User = username;
        Group = hostUser.group;
        NoNewPrivileges = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        SystemCallArchitectures = "native";
        LimitCORE = 0;
      };
    }
  );

  captureBrokerService = helper (
    afterPrep [ (ref "${unit}-gpu") ]
    // {
      description = "Sandbox VM screen-capture injection helper: ${label}";
      environment.__EGL_VENDOR_LIBRARY_FILENAMES = "/run/opengl-driver/share/glvnd/egl_vendor.d/10_nvidia.json";
      serviceConfig = {
        ExecStart = "${captureBrokerScript}${instArg}";
        User = captureUserName;
        Group = captureUserName;
        # The render node's group; the NVIDIA nodes are the driver's 0666.
        SupplementaryGroups = [ "render" ];
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ base ];
        PrivateTmp = true;
        PrivateIPC = true;
        PrivateNetwork = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        RestrictNamespaces = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" ];
        SystemCallErrorNumber = "EPERM";
        # Not MemoryDenyWriteExecute: libglvnd writes its dispatch stubs.
        DevicePolicy = "closed";
        DeviceAllow = captureDeviceAllow;
        LimitCORE = 0;
        UMask = "0077";
      };
    }
  );
  captureBusService = helper (
    afterPrep [
      (ref "${unit}-bus")
      (ref "${unit}-capture-broker")
    ]
    // {
      description = "Sandbox VM D-Bus capture adapter: ${label}";
      serviceConfig = {
        ExecStart = "${captureBusScript}${instArg}";
        ExecStartPost = lib.optional restricted "${grantBusSocket} capture.sock";
        User = username;
        Group = hostUser.group;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        # Only this VM's runtime dir: not the session bus, the compositor or
        # PipeWire under /run/user, and nothing in /home.
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ base ];
        PrivateTmp = true;
        PrivateIPC = true;
        PrivateDevices = true;
        PrivateNetwork = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        RestrictNamespaces = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" ];
        SystemCallErrorNumber = "EPERM";
        UMask = "0077";
        LimitCORE = 0;
        # It buffers what the guest sends: a misbehaving guest costs this
        # unit (and so its own screen sharing and bus), not the session.
        MemoryMax = "512M";
        MemorySwapMax = 0;
        TasksMax = 512;
      };
    }
  );

  grantsFsService = helper (
    afterPrep [ ]
    // {
      description = "Sandbox VM folder grants (virtio-fs): ${label}";
      serviceConfig = {
        ExecStart = "${grantsFsScript}${instArg}";
        User = username;
        Group = hostUser.group;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        # Only this user's home is visible (it's the share); the rest of the
        # host is read-only and the other data trees hidden.
        ProtectSystem = "strict";
        ProtectHome = "tmpfs";
        BindPaths = [ home ];
        ReadWritePaths = [ base ];
        InaccessiblePaths = [
          "-/persist"
          "-/large"
          "-/cache"
        ];
        RestrictNamespaces = "user pid mnt net";
        SystemCallFilter = core.hardening.jailedSyscallFilter;
        SystemCallErrorNumber = "EPERM";
        PrivateTmp = true;
        PrivateIPC = true;
        PrivateNetwork = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        SystemCallArchitectures = "native";
        UMask = "0077";
        LimitCORE = 0;
      };
    }
  );

  # Not a helper: attaching must never start the VM (Requisite=), and it goes
  # when the VM does (PartOf=).
  cameraService = {
    description = "Sandbox VM camera (USB passthrough): ${label}";
    requisite = [ (ref unit) ];
    after = [ (ref unit) ];
    partOf = [ (ref unit) ];
    restartIfChanged = false;
    stopIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${cameraAttach}${instArg}";
      ExecStop = "${cameraDetach}${instArg}";
      PrivateNetwork = true;
      ProtectHome = true;
      NoNewPrivileges = true;
      DevicePolicy = "closed";
      DeviceAllow = [ "char-usb_device rw" ];
      RestrictAddressFamilies = [ "AF_UNIX" ];
    };
  };

  docsPortalService = helper (
    afterPrep [ ]
    // {
      description = "Sandbox VM documents (portal activation): ${label}";
      environment = {
        XDG_RUNTIME_DIR = hostRuntimeDir;
        DBUS_SESSION_BUS_ADDRESS = "unix:path=${hostRuntimeDir}/bus";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${docsPortalScript}";
        User = username;
        Group = hostUser.group;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        ProtectSystem = "strict";
        ProtectHome = "tmpfs";
        # ProtectHome also hides /run/user: the session bus and the portal's
        # FUSE mount (which may appear only once GetMountPoint has activated
        # the portal) are in this user's runtime dir. Nothing here reads the
        # guest's input; the device that does is -docs.
        BindPaths = [ hostRuntimeDir ];
        PrivateTmp = true;
        PrivateIPC = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" ];
        SystemCallErrorNumber = "EPERM";
        LimitCORE = 0;
      };
    }
  );

  docsService = helper (
    afterPrep [ (ref "${unit}-docs-portal") ]
    // {
      description = "Sandbox VM documents (portal files, virtio-fs): ${label}";
      serviceConfig = {
        ExecStart = "${docsScript}${instArg}";
        User = username;
        Group = hostUser.group;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        ProtectSystem = "strict";
        # Nothing of /home or /run/user: only this app's document view, bound by
        # systemd (as root, from the host root) at docsView.
        ProtectHome = true;
        BindPaths = [ "${docsSource}:${docsView}" ];
        ReadWritePaths = [ base ];
        # Own network namespace: no abstract unix sockets of the host's (the
        # fs device talks to the VMM over the vhost-user socket in base).
        PrivateNetwork = true;
        RestrictNamespaces = "user pid mnt net";
        SystemCallFilter = core.hardening.jailedSyscallFilter;
        SystemCallErrorNumber = "EPERM";
        PrivateTmp = true;
        PrivateIPC = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        SystemCallArchitectures = "native";
        LimitCORE = 0;
      };
    }
  );

  grantsHubService = helper (
    afterPrep [ (ref "${unit}-grantsfs") ]
    // {
      description = "Sandbox VM folder grants (hub): ${label}";
      serviceConfig = {
        ExecStart = "${grantsHubScript}${instArg}";
        User = username;
        Group = hostUser.group;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ReadWritePaths = [ base ];
        PrivateTmp = true;
        PrivateNetwork = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        SystemCallArchitectures = "native";
        UMask = "0077";
        LimitCORE = 0;
      };
    }
  );

  entryPaths = map (e: e.path) entries;
in
{
  inherit
    unit
    spec
    launcherFor
    gui
    x11
    nvgpu
    bus
    fido
    pwdBinds
    ;

  # systemd.services for this instance.
  services = {
    "${unit}${tmpl}" = vmmService;
    "${unit}-prep${tmpl}" = prepService;
  }
  // lib.optionalAttrs network' { "${unit}-net${tmpl}" = netService; }
  // lib.optionalAttrs gui { "${unit}-wl${tmpl}" = wlService; }
  // lib.optionalAttrs gpuDevice { "${unit}-gpu${tmpl}" = gpuService; }
  // lib.optionalAttrs relay { "${unit}-relay${tmpl}" = relayService; }
  // lib.optionalAttrs bus { "${unit}-bus${tmpl}" = busService; }
  // lib.optionalAttrs capture {
    "${unit}-capture-broker${tmpl}" = captureBrokerService;
    "${unit}-capture-bus${tmpl}" = captureBusService;
  }
  // lib.optionalAttrs docs {
    "${unit}-docs-portal${tmpl}" = docsPortalService;
    "${unit}-docs${tmpl}" = docsService;
  }
  // lib.optionalAttrs camera { "${unit}-camera${tmpl}" = cameraService; }
  // lib.optionalAttrs grants {
    "${unit}-grantsfs${tmpl}" = grantsFsService;
    "${unit}-grants${tmpl}" = grantsHubService;
  };

  # The broker's view of this VM (modules.sandbox.broker.sandboxes.<brokerName>).
  inherit brokerName;
  brokerEntry = {
    label = "${label} (VM)";
    # A restricted VM's relay connects as the principal: the broker ACLs this
    # VM's sockets for it.
    uid = if restricted then principal else null;
    netUnits = lib.optional network' netUnitPattern;
    grantPaths = if grants then "${grantPathsScript}" else null;
    camera = if camera then "${cameraCtl}" else null;
    # The broker's PulseAudio filter (lib/broker/broker.py), which the relay's
    # pulse service reaches: playback, and recording after approval if any
    # member has the microphone capability.
    audio =
      if !audio then
        null
      else if anyCap "microphone" then
        "microphone"
      else
        "playback";
    inherit fido;
  };

  # The backend's own user and group (nvgpu only), for users.users/groups.
  gpuUsers = lib.optionalAttrs nvgpu {
    users = {
      ${gpuUserName} = {
        isSystemUser = true;
        group = gpuUserName;
        description = "virtio-nvgpu backend of sandbox VM ${name}";
      };
    }
    // lib.optionalAttrs capture {
      ${captureUserName} = {
        isSystemUser = true;
        group = captureUserName;
        description = "Screen-capture helper of sandbox VM ${name} (inject only)";
      };
    };
    groups = {
      ${gpuUserName} = { };
    }
    // lib.optionalAttrs capture { ${captureUserName} = { }; };
  };

  # For sbx-dnsallow (modules.sandbox.dnsAllow).
  dnsAllow = lib.optional (network' && netPolicy.names != [ ]) {
    units = [ netUnitPattern ];
    inherit (netPolicy) names;
  };

  # For the polkit allowlist (modules/system/sandbox.nix): the user starts/stops
  # only the VM unit; its helpers come along as dependencies.
  polkitUnits = lib.optionals (!perCwd) (
    [ "${unit}.service" ] ++ lib.optional camera "${unit}-camera.service"
  );
  polkitTemplates = lib.optionals perCwd ([ "${unit}@" ] ++ lib.optional camera "${unit}-camera@");

  assertions = [
    {
      assertion = (network.allowNames or [ ]) == [ ] || config.services.resolved.enable;
      message = "sandbox VM '${name}': network.allowNames needs systemd-resolved on the host.";
    }
    {
      assertion = !lib.any (n: lib.elem n builtinRelays) (lib.attrNames extraRelays);
      message = "sandbox VM '${name}': sandbox.vm.relays can't reuse the built-in service names (${lib.concatStringsSep ", " builtinRelays}).";
    }
    {
      assertion = lib.all (t: lib.hasPrefix "/" (expandHome' t)) (lib.attrNames guestBinds);
      message = "sandbox VM '${name}': sandbox.vm.guestBinds targets must be absolute or ~/-relative.";
    }
    {
      assertion = lib.all (m: m.principal == principal) members;
      message = "sandbox VM '${name}': its apps' data belongs to different users (${
        lib.concatMapStringsSep ", " (m: "${m.appName}: ${m.principal}") members
      }); one VM can only serve one principal.";
    }
    {
      assertion = !perCwd || principal == username;
      message = "sandbox VM '${name}': attaching the working directory (capabilities.cwd) needs the VM to run as ${username}; a dedicated app uid can't read the user's project.";
    }
    {
      assertion = projects == [ ] || principal == username;
      message = "sandbox VM '${name}': sharing projects needs the VM to run as ${username}.";
    }
    {
      assertion = lib.length entryPaths == lib.length (lib.unique entryPaths);
      message = "sandbox VM '${name}': two apps store data at the same path (${
        lib.concatStringsSep ", " (
          lib.unique (lib.filter (p: lib.count (q: q == p) entryPaths > 1) entryPaths)
        )
      }).";
    }
    {
      # One capture helper uid per VM (virtio-nvgpu's DEPLOY.md): per-project
      # instances would all share sbx-cap-<name>, each able to inject into all.
      assertion = !(capture && perCwd);
      message = "sandbox VM '${name}': screen capture (ScreenCast) isn't supported for per-project (cwd) VMs.";
    }
    {
      assertion = username == vmHost.user;
      message = "sandbox VM '${name}': its user (${username}) differs from the VM guest user (modules.sandbox.vm.user = ${vmHost.user}).";
    }
  ];
}
