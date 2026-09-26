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
#   - audio → the user's PulseAudio socket, and the members' D-Bus policy → a
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
}:
let
  paths = import ../paths.nix { inherit lib; };
  netpolicy = import ../netpolicy.nix { inherit lib; };
  vmHost = config.modules.sandbox.vm;
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
  nvgpu = vmHost.graphics == "nvgpu" && (gui || gpuCap);
  crossDomain = vmHost.graphics == "cross-domain" && gui;
  gpuDevice = nvgpu || crossDomain;
  crosvmPkg = if nvgpu then vmHost.nvgpu.crosvm else pkgs.crosvm;
  # The guest's Wayland socket (mirrors guest-graphics.nix) and the host
  # compositor's, pinned like the systemd backend's.
  guestWaylandDisplay = if vmHost.graphics == "nvgpu" then "/run/sbx/wl/wayland-0" else "wayland-0";
  guestRuntimeDir = "/run/user/${guestUid}";
  hostRuntimeDir = "/run/user/${guestUid}";
  hostWaylandSocket = "wayland-1";
  wlSecure = import ../backends/wayland-security-context.nix pkgs;

  netPolicy = netpolicy.lower {
    policy = network;
    backendDefault = "internet";
    dns = vmHost.dns;
  };

  # ── Host services over vsock (lib/vm/vsock-relay.py) ─────────────────────────
  # Audio: the user's PulseAudio socket (pipewire-pulse), no shm/memfd since file
  # descriptors can't cross vsock. D-Bus: an xdg-dbus-proxy with the members' own
  # filter (the same policy the container backends apply) and a flatpak identity,
  # so the portals treat it as that sandboxed app.
  audio = anyCap "audio";
  dbusArgs = lib.unique (lib.concatMap (m: if m.dbusArgs == null then [ ] else m.dbusArgs) members);
  flatpakInfoFile = lib.findFirst (i: i != null) null (map (m: m.flatpakInfoFile) members);
  bus = dbusArgs != [ ] && flatpakInfoFile != null;
  # The sandbox broker (modules/system/sandbox-broker.nix): escapes and grants.
  broker = config.modules.sandbox.broker.enable;
  brokerName = "vm-${name}";
  # Temporary folder grants (lib/vm/grants.py): a virtio-fs share of the user's
  # home behind an allowlist that starts empty. Only when the VM runs as the user.
  grants = principal == username;
  # Files the portals hand this app (FileChooser results, drag and drop): the
  # document portal's view for the VM's flatpak identity, shared like flatpak
  # binds it (by-app/<id> at $XDG_RUNTIME_DIR/doc), so only this app's documents.
  docs = bus;
  # Security keys: a virtual FIDO device in the guest, relayed through the
  # broker to whichever key is plugged in (lib/vm/fido-guest.py).
  fido = anyCap "fido" && broker;
  grantCwd' = grantCwd && grants;
  grantsPkg = import ./grants.nix pkgs;
  crosvmFs = import ./crosvm-fs.nix pkgs;
  # Other modules' services (sandbox.vm.relays), merged across members.
  extraRelays = lib.foldl' (a: m: a // m.relays) { } members;
  builtinRelays = [
    "pulse"
    "dbus"
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
    cid=$(( 3 + 16#$(printf '%s/%s' ${lib.escapeShellArg name} "$id" | ${co}/sha256sum | ${co}/cut -c1-7) ))
  '';

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
      guestBinds = lib.mapAttrsToList (target: source: {
        target = expandHome' target;
        inherit source;
      }) guestBinds;
      services = lib.mapAttrsToList (n: sv: {
        name = n;
        inherit (sv) argv group;
        env =
          [ "XDG_RUNTIME_DIR=${guestRuntimeDir}" ]
          ++ lib.optionals gui [ "WAYLAND_DISPLAY=${guestWaylandDisplay}" ]
          ++ lib.optionals bus [ "DBUS_SESSION_BUS_ADDRESS=unix:path=${guestSockets.dbus}" ];
      }) guestServices;
      # Guest sockets for the relay (the grant agent dials the host directly).
      relay = map (n: {
        name = n;
        path = guestSockets.${n};
      }) (lib.remove "grants" relayServices);
    }
  );

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
      ${co}/install -d -m 0700 -o ${principal} -g ${principalGroup} "$rt/gpu"
    ''}
    ${lib.optionalString bus ''
      ${co}/install -d -m 0700 -o ${username} -g ${hostUser.group} "$rt/bus"
    ''}
    ${lib.optionalString grants ''
      ${co}/install -d -m 0700 -o ${username} -g ${hostUser.group} "$rt/grants"
    ''}
    ${lib.optionalString docs ''
      ${co}/install -d -m 0711 -o ${username} -g ${hostUser.group} "$rt/docs"
    ''}
    ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "${unit}" -f "$rt/meta/ssh_host_ed25519_key"
    ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "${username}@${unit}" -f "$rt/client/id_ed25519"
    ${co}/install -m 0644 "$rt/client/id_ed25519.pub" "$rt/meta/authorized_keys"
    printf 'sandbox-vm %s\n' "$(${co}/cut -d' ' -f1,2 "$rt/meta/ssh_host_ed25519_key.pub")" > "$rt/client/known_hosts"
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
  fsCommon = "type=fs:posix_acl=false:security_ctx=false";
  guestKernelParams = guest.boot.kernelParams ++ [
    "init=${guest.system.build.toplevel}/init"
    "sbx.spec=${spec}"
  ];
  runScript = pkgs.writeShellScript "${unit}-run" ''
    set -euo pipefail
    dir="''${1:-}"
    ${idPrelude}
    eu="$(${co}/id -u)"
    eg="$(${co}/id -g)"
    # Writable shares: the guest user (uid ${guestUid}) is this VMM's uid on the host.
    rw="${fsCommon}:cache=auto:uid=${guestUid}:gid=${guestGid}:uidmap=${guestUid} $eu 1:gidmap=${guestGid} $eg 1"
    args=(
      run
      --name ${lib.escapeShellArg "sbx-${name}"}
      --mem size=${toString memory}
      --cpus num-cores=${toString vcpus}
      --no-usb
      --balloon-page-reporting
      --serial type=stdout,hardware=serial,console=true
      --vsock "cid=$cid"
      -s "$rt/ctl/crosvm.sock"
      --shared-dir "/nix/store:nixstore:${fsCommon}:cache=always:timeout=3600"
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
    exec ${crosvm} "''${args[@]}" \
      --initrd ${guest.system.build.initialRamdisk}/${guest.system.boot.loader.initrdFile} \
      ${guest.boot.kernelPackages.kernel}/${guest.system.boot.loader.kernelFile}
  '';

  # ACPI power button → orderly guest shutdown; systemd kills whatever remains.
  stopScript = pkgs.writeShellScript "${unit}-stop" ''
    dir="''${1:-}"
    ${idPrelude}
    exec ${crosvm} powerbtn "$rt/ctl/crosvm.sock"
  '';

  # Principal: user-mode networking for the guest (DHCP, DNS, NAT via host
  # sockets). No inbound forwarding, no route to the host's loopback.
  netScript = pkgs.writeShellScript "${unit}-net" ''
    set -euo pipefail
    dir="''${1:-}"
    ${idPrelude}
    exec ${pkgs.passt}/bin/passt --foreground --quiet --vhost-user \
      --socket "$rt/net/passt.sock" \
      -t none -u none --no-map-gw \
      ${lib.concatMapStringsSep " " (d: "--dns ${lib.escapeShellArg d}") vmHost.dns}
  '';

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
    ${lib.optionalString (principal != username) ''
      ${pkgs.acl}/bin/setfacl -m "u:${principal}:rw" "$sock"
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
          exec ${vmHost.nvgpu.backend}/bin/vhost-user-nvgpu --socket "$rt/gpu/gpu.sock" ${lib.optionalString gui ''--wayland-socket "$rt/wl/wayland.sock"''} ${lib.optionalString gpuCap "--allow-compute"}
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

  # The user: the document portal's by-app view for this VM's flatpak identity,
  # over virtio-fs (crosvm's jailed fs device; the portal's FUSE enforces the
  # per-app view). The portal is D-Bus activated, so it's started first.
  docsScript = pkgs.writeShellScript "${unit}-docs" ''
    set -euo pipefail
    dir="''${1:-}"
    ${idPrelude}
    eu="$(${co}/id -u)"
    eg="$(${co}/id -g)"
    appid="$(${pkgs.gnused}/bin/sed -n 's/^name=//p' ${busFlatpakInfo} | ${co}/head -n1)"
    ${pkgs.systemd}/bin/busctl --user call org.freedesktop.portal.Documents \
      /org/freedesktop/portal/documents org.freedesktop.portal.Documents GetMountPoint >/dev/null
    src="${hostRuntimeDir}/doc/by-app/$appid"
    for _ in $(${co}/seq 1 100); do [ -d "$src" ] && break; ${co}/sleep 0.05; done
    ${co}/rm -f "$rt/docs/fs.sock"
    ${pkgs.crosvm}/bin/crosvm device fs \
      --socket-path "$rt/docs/fs.sock" \
      --tag sbx-docs \
      --shared-dir "$src" \
      --cfg cache=never,posix_acl=false,security_ctx=false \
      --uid "$eu" --gid "$eg" \
      --uid-map "$eu $eu 1" --gid-map "$eg $eg 1" &
    pid=$!
    ${lib.optionalString (principal != username) ''
      for _ in $(${co}/seq 1 200); do [ -S "$rt/docs/fs.sock" ] && break; ${co}/sleep 0.05; done
      ${pkgs.acl}/bin/setfacl -m "u:${principal}:rw" "$rt/docs/fs.sock"
    ''}
    wait "$pid"
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

  # Host-GPU device nodes for the virtio-nvgpu backend: the host's
  # modules.sandbox.gpuDevices narrowing when set (multi-GPU hosts), else every
  # NVIDIA and DRM node.
  nvgpuDeviceAllow =
    (
      if config.modules.sandbox.gpuDevices != null then
        map (d: if d == "/dev/dri" then "char-drm rw" else "${d} rw") config.modules.sandbox.gpuDevices
      else
        [
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

  # The user: this VM's end of the vsock relay, on port = its CID, answering only
  # that CID, and only for the services it was given.
  relayScript = pkgs.writeShellScript "${unit}-relay" ''
    set -euo pipefail
    dir="''${1:-}"
    ${idPrelude}
    exec ${vsockRelay}/bin/vsock-relay host --cid "$cid" ${
      lib.concatStringsSep " " (
        lib.optional audio "pulse=${hostRuntimeDir}/pulse/native"
        ++ lib.optional bus ''dbus="$rt/bus/bus.sock"''
        ++ lib.optional broker "broker=${hostRuntimeDir}/sbx-broker/${brokerName}.sock"
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
        ${lib.concatMapStringsSep " " lib.escapeShellArg (dbusArgs ++ [ "--filter" ])}
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
        if ${ssh} "''${ssh_opts[@]}" -o ConnectTimeout=2 -T -- "vsock/$cid" true 2>/dev/null; then
          up=1
          break
        fi
        ${systemctl} is-active --quiet "$unit" || break
        ${co}/sleep 0.25
      done
      if [ "$up" != 1 ]; then
        echo "${member.bin}: the VM did not come up (see: journalctl -u '$unit')" >&2
        finish 1
      fi
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
      genv=("PATH=${
        lib.concatMapStrings (m: "${m.package}/bin:") (
          [ member ] ++ lib.filter (m: m.appName != member.appName) members
        )
      }/run/current-system/sw/bin:$hostsw/bin")
      ${lib.optionalString audio ''
        genv+=("PULSE_SERVER=unix:${guestSockets.pulse}" "PULSE_CLIENTCONFIG=${pulseClientConf}")
      ''}
      ${lib.optionalString bus ''
        genv+=("DBUS_SESSION_BUS_ADDRESS=unix:path=${guestSockets.dbus}")
      ''}
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
        for kv in NIXOS_OZONE_WL=1 ELECTRON_OZONE_PLATFORM_HINT=wayland MOZ_ENABLE_WAYLAND=1 \
                  "QT_QPA_PLATFORM=wayland;xcb" QT_QPA_PLATFORMTHEME=qt6ct \
                  XDG_CURRENT_DESKTOP=Hyprland XDG_SESSION_TYPE=wayland; do
          case " ''${genv[*]} " in *" ''${kv%%=*}="*) ;; *) genv+=("$kv") ;; esac
        done
        fc="$(${co}/readlink -f /etc/fonts/fonts.conf 2>/dev/null || true)"
        if [ -n "$fc" ]; then genv+=("FONTCONFIG_FILE=$fc"); fi
        genv+=(
          "XDG_RUNTIME_DIR=${guestRuntimeDir}"
          "WAYLAND_DISPLAY=${guestWaylandDisplay}"
          ${lib.optionalString x11 ''"DISPLAY=:0"''}
          ${
            if nvgpu then
              # Pin every loader to NVIDIA's files (as virtio-nvgpu's guest does), so
              # a broken NVIDIA ICD fails loudly instead of falling back to Mesa.
              ''
                "VK_DRIVER_FILES=/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.json"
                "__EGL_VENDOR_LIBRARY_FILENAMES=/run/opengl-driver/share/glvnd/egl_vendor.d/10_nvidia.json"
                "__GLX_VENDOR_LIBRARY_NAME=nvidia"
                "GBM_BACKENDS_PATH=/run/opengl-driver/lib/gbm"
              ''
            else
              # No host GPU behind cross-domain: render in software.
              ''
                "LIBGL_ALWAYS_SOFTWARE=1"
                "GALLIUM_DRIVER=llvmpipe"
              ''
          }
        )
      ''}
      remote="cd $(printf '%q' "$workdir") && exec env $(printf '%q ' "''${genv[@]}" ${member.package}/bin/${member.bin} "$@")"
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
      ExecStop = "-${stopScript}${instArg}";
      TimeoutStopSec = 20;
      KillMode = "mixed";
      Restart = "no";

      User = principal;
      Group = principalGroup;
      SupplementaryGroups = [ "kvm" ];
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      AmbientCapabilities = "";

      # crosvm's own sandbox builds user/pid/mount/net namespaces and pivots its
      # device processes into empty roots, so those namespace types, the mount
      # syscalls and seccomp itself must stay available. Never deny @privileged as
      # a group: pivot_root is in it.
      RestrictNamespaces = "user pid mnt net";
      SystemCallFilter = [
        "@system-service"
        "@mount"
        "@sandbox"
        "~@obsolete @raw-io @reboot @swap @module @cpu-emulation @debug @clock"
      ];
      SystemCallArchitectures = "native";
      SystemCallErrorNumber = "EPERM";
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      MemoryDenyWriteExecute = true;

      # The host filesystem is read-only and the user's data invisible, apart from
      # the members' storage/binds (BindPaths, set up by systemd as root) and the
      # runtime dir.
      ProtectSystem = "strict";
      ProtectHome = "tmpfs";
      InaccessiblePaths = [
        "-/persist"
        "-/large"
        "-/cache"
      ];
      BindPaths = storageBinds ++ rwBinds ++ lib.optional perCwd (bindPair "%f" cwdMount);
      BindReadOnlyPaths = roBinds;
      ReadWritePaths = [ base ];
      PrivateTmp = true;
      PrivateIPC = true;
      KeyringMode = "private";
      UMask = "0077";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      # Not ProcSubset=pid: minijail reads /proc/sys/kernel/cap_last_cap.
      ProtectProc = "invisible";

      DevicePolicy = "closed";
      DeviceAllow = [
        "/dev/kvm rw"
        "/dev/vhost-vsock rw"
      ];
      # No IP at all: the guest's network (if any) is passt, over a unix socket.
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_NETLINK"
      ];
      IPAddressDeny = "any";

      LimitCORE = 0;
      MemoryMax = "${toString (memory + 512)}M";
      MemorySwapMax = 0;
      TasksMax = 1024;
      OOMPolicy = "stop";
    };
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
      serviceConfig = {
        ExecStart = "${netScript}${instArg}";
        User = principal;
        Group = principalGroup;
        # The network policy (lib/netpolicy.nix; VMs default to "internet": not
        # the host, the LAN, the tailnet or container/VM bridges). passt makes
        # every outbound connection from this unit, so the cgroup filter applies to
        # all of the guest's traffic.
        IPAddressAllow = netPolicy.ipAddressAllow;
        IPAddressDeny = netPolicy.ipAddressDeny;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ base ];
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
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
        UMask = "0077";
        LimitCORE = 0;
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
      serviceConfig = {
        ExecStart = "${gpuScript}${instArg}";
        User = principal;
        Group = principalGroup;
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
      };
    }
  );

  relayService = helper (
    afterPrep (lib.optional bus (ref "${unit}-bus") ++ lib.optional grants (ref "${unit}-grants"))
    // {
      description = "Sandbox VM host services (vsock relay): ${label}";
      serviceConfig = {
        # Ready once the vsock port is bound.
        Type = "notify";
        NotifyAccess = "main";
        ExecStart = "${relayScript}${instArg}";
        User = username;
        Group = hostUser.group;
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
        SystemCallFilter = [
          "@system-service"
          "@mount"
          "@sandbox"
          "~@obsolete @raw-io @reboot @swap @module @cpu-emulation @debug @clock"
        ];
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

  docsService = helper (
    afterPrep [ ]
    // {
      description = "Sandbox VM documents (portal files, virtio-fs): ${label}";
      environment = {
        XDG_RUNTIME_DIR = hostRuntimeDir;
        DBUS_SESSION_BUS_ADDRESS = "unix:path=${hostRuntimeDir}/bus";
      };
      serviceConfig = {
        ExecStart = "${docsScript}${instArg}";
        User = username;
        Group = hostUser.group;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        ProtectSystem = "strict";
        ProtectHome = "tmpfs";
        ReadWritePaths = [ base ];
        RestrictNamespaces = "user pid mnt net";
        SystemCallFilter = [
          "@system-service"
          "@mount"
          "@sandbox"
          "~@obsolete @raw-io @reboot @swap @module @cpu-emulation @debug @clock"
        ];
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
  // lib.optionalAttrs docs { "${unit}-docs${tmpl}" = docsService; }
  // lib.optionalAttrs grants {
    "${unit}-grantsfs${tmpl}" = grantsFsService;
    "${unit}-grants${tmpl}" = grantsHubService;
  };

  # The broker's view of this VM (modules.sandbox.broker.sandboxes.<brokerName>).
  inherit brokerName;
  brokerEntry = {
    label = "${label} (VM)";
    netUnits = lib.optional network' (
      if perCwd then "${unit}-net@*.service" else "${unit}-net.service"
    );
    grantPaths = if grants then "${grantPathsScript}" else null;
    inherit fido;
  };

  # For the polkit allowlist (modules/system/sandbox.nix): the user starts/stops
  # only the VM unit; its helpers come along as dependencies.
  polkitUnits = lib.optional (!perCwd) "${unit}.service";
  polkitTemplates = lib.optional perCwd "${unit}@";

  assertions = [
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
      assertion = username == vmHost.user;
      message = "sandbox VM '${name}': its user (${username}) differs from the VM guest user (modules.sandbox.vm.user = ${vmHost.user}).";
    }
  ];
}
