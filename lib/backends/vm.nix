# vm backend — the app runs inside its own crosvm microVM.
#
# Unlike the container backends this is not chosen by app.defaultBackend: every
# app evaluates it NEXT TO its container backend (lib/apps.nix), and
# modules.apps.<name>.sandbox.mode picks which one the app's command runs. Both
# work on the SAME data, so switching is free:
#
#   - The VMM runs as the uid that already owns the app's stash (`principal`: the
#     user, or app-<name> for a systemd dedicatedUser app). Each storage entry is
#     bind-mounted (by systemd, as root, BindPaths=) into a per-tier tree inside the
#     unit's private mount namespace, shared over crosvm's jailed virtio-fs device
#     (sbx-<tier>), and grafted back onto ~/<path> in the guest (lib/vm/guest.nix).
#     The guest user appears as that uid on the host (single-entry uidmap), so
#     nothing is chowned when switching between container and vm.
#   - Apps with capabilities.cwd get one VM per project directory: a template unit
#     sandbox-vm-<app>@<escaped path>, with the directory shared at the same
#     absolute path. Everything else gets a single sandbox-vm-<app> unit.
#   - The guest is the host-wide generic system (modules.sandbox.vm.guest) booting
#     from the host's read-only /nix/store; the app's spec (a store path on the
#     kernel command line) tells it what to mount.
#   - The launcher (the app's command, run as the user) starts the unit through the
#     polkit allowlist, then runs the app over SSH on vsock with keys generated
#     fresh by root for every VM start. The last session out stops the VM.
#   - capabilities.network → a virtio-net NIC backed by passt in its own unit, as
#     the principal, with IPAddressDeny= keeping the guest off loopback, the LAN
#     and the tailnet. No network capability → no NIC at all.
#
# Not lowered yet (the app still starts, without them): GUI/Wayland and GPU
# (graphics wiring comes later), audio, x11, fido, device binds, D-Bus policies,
# ./-relative binds, raw nixpakModules and variantCommands. Selecting mode = "vm"
# for an app that uses any of these emits a warning listing them.
#
# Security shape: the app's code runs behind KVM; the host-side attack surface is
# crosvm (per-device minijail processes with seccomp, the main process confined by
# the systemd unit below) and passt. The VMM uid can reach only this app's stash
# and the explicitly shared paths. (BindPaths= sources are resolved against the
# host root, not the namespace being built — systemd's namespace.c — so hiding
# /home and /persist from the unit doesn't hide them from its binds.) UNVERIFIED
# on hardware so far: the unit's syscall filter and MemoryDenyWriteExecute with
# crosvm's sandbox, and passt's vhost-user mode with crosvm's vhost-user net
# frontend.
{
  appName,
  appCfg,
  cfg,
  config,
  lib,
  pkgs,
  storage,
  # The uid/group that owns the app's data and runs the VMM (see above).
  principal,
  principalGroup,
  # Package whose share/ provides .desktop entries and icons: the container
  # backend's, whose Exec= lines already name the app's command.
  desktopSource,
}:
let
  paths = import ../paths.nix { inherit lib; };
  variants = import ../variants.nix { inherit lib pkgs; };

  username = builtins.head appCfg.defaultUsernames;
  home = "/home/${username}";
  hostUser = config.users.users.${username};
  guestUid = toString hostUser.uid;
  guestGid = toString config.users.groups.${hostUser.group}.gid;

  bin = appCfg.packageName;
  caps = appCfg.capabilities;
  vmCfg = cfg.sandbox.vm;
  guest = config.modules.sandbox.vm.guest.config;

  perCwd = caps.cwd;
  network = caps.network;

  unit = "sandbox-vm-${appName}";
  tmpl = lib.optionalString perCwd "@";
  # Units reference each other per instance; scripts get the project path.
  ref = u: if perCwd then "${u}@%i.service" else "${u}.service";
  # %f = the instance unescaped as a path, with its leading "/" (%I drops it).
  instArg = lib.optionalString perCwd " \"%f\"";

  # /run/sandbox-vm/<app>: <id>/ holds one launch's keys and sockets (root prep,
  # removed on stop); tree/ and cwd/ are mount points for the unit's private binds
  # (empty on the host, so concurrent per-project instances can share them).
  base = "/run/sandbox-vm/${appName}";
  tree = "${base}/tree";
  cwdMount = "${base}/cwd";

  co = "${pkgs.coreutils}/bin";
  crosvm = "${pkgs.crosvm}/bin/crosvm";
  systemctl = "${pkgs.systemd}/bin/systemctl";
  flock = "${pkgs.util-linux}/bin/flock";
  ssh = "${pkgs.openssh}/bin/ssh";

  # From $dir (the project path, "" for single-VM apps): the launch id, its
  # runtime dir and the VM's vsock CID. Shared verbatim by the launcher and every
  # unit script, which is how the launcher finds the VM's keys and address.
  idPrelude = ''
    if [ -n "$dir" ]; then
      id="$(printf '%s' "$dir" | ${co}/sha256sum | ${co}/cut -c1-16)"
    else
      id=main
    fi
    rt="${base}/$id"
    cid=$(( 3 + 16#$(printf '%s/%s' ${lib.escapeShellArg appName} "$id" | ${co}/sha256sum | ${co}/cut -c1-7) ))
  '';

  # ── Storage and binds ────────────────────────────────────────────────────────
  entries = storage.entries; # parent-first
  tiers = lib.unique (map (e: e.tier) entries);
  entrySource = e: if e.location == "stash" then e.stashPath else "${home}/${e.path}";

  bindReqs =
    lib.optionals caps.gitConfig [
      {
        path = ".gitconfig";
        ro = true;
      }
      {
        path = ".config/git";
        ro = true;
      }
    ]
    ++ map (p: {
      path = p;
      ro = true;
    }) caps.binds.ro
    ++ map (p: {
      path = p;
      ro = false;
    }) (caps.binds.rw ++ cfg.sandbox.extraBinds);
  pwdBinds = lib.filter (b: paths.isPwdRelative b.path) bindReqs;
  # Absolute and home-relative binds keep their host path inside the guest.
  binds = lib.imap0 (
    i: b:
    b
    // {
      index = i;
      source = if paths.isAbsolute b.path then b.path else "${home}/${b.path}";
    }
  ) (lib.filter (b: !(paths.isPwdRelative b.path)) bindReqs);

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
      app = appName;
      inherit tiers;
      entries = map (e: { inherit (e) tier path; }) entries;
      binds = map (b: {
        inherit (b) index;
        target = b.source;
      }) binds;
      cwd = perCwd;
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
    ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "sandbox-vm-${appName}" -f "$rt/meta/ssh_host_ed25519_key"
    ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "${username}@sandbox-vm-${appName}" -f "$rt/client/id_ed25519"
    ${co}/install -m 0644 "$rt/client/id_ed25519.pub" "$rt/meta/authorized_keys"
    printf 'sandbox-vm %s\n' "$(${co}/cut -d' ' -f1,2 "$rt/meta/ssh_host_ed25519_key.pub")" > "$rt/client/known_hosts"
    if [ -n "$dir" ]; then printf '%s' "$dir" > "$rt/meta/cwd"; fi
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
      --name ${lib.escapeShellArg "sbx-${appName}"}
      --mem size=${toString vmCfg.memory}
      --cpus num-cores=${toString vmCfg.vcpus}
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
    ${lib.optionalString network ''
      for _ in $(${co}/seq 1 200); do [ -S "$rt/net/passt.sock" ] && break; ${co}/sleep 0.05; done
      if [ ! -S "$rt/net/passt.sock" ]; then
        echo "${unit}: passt never created its socket; see the journal of the matching ${unit}-net unit" >&2
        exit 1
      fi
      args+=(--vhost-user "type=net,socket=$rt/net/passt.sock")
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
      ${lib.concatMapStringsSep " " (d: "--dns ${lib.escapeShellArg d}") config.modules.sandbox.vm.dns}
  '';

  # The user's command. Per-project apps run in the VM for the physical $PWD.
  launcher = pkgs.writeShellScript "${unit}-launch" ''
    set -euo pipefail
    ${
      if perCwd then
        ''
          dir="$(pwd -P)"
          # The path travels through a unit instance name, a systemd ExecStart line
          # and the guest, so only plain path characters are accepted.
          case "$dir" in
            /)
              echo "${bin}: sandbox-vm won't attach / (the whole host filesystem) as a project" >&2
              exit 1 ;;
            *[!A-Za-z0-9._/@+,=~\ -]*)
              echo "${bin}: sandbox-vm can't attach '$dir' (supported path characters: A-Z a-z 0-9 . _ / @ + , = ~ - and space)" >&2
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
        ''
    }
    ${idPrelude}

    # Session accounting: every launcher holds a shared lock for its lifetime; the
    # one that can upgrade it to exclusive on the way out is the last, and stops
    # the VM.
    lockdir="''${XDG_RUNTIME_DIR:-/run/user/$(${co}/id -u)}/sandbox-vm"
    ${co}/mkdir -p -m 0700 "$lockdir"
    exec 9>"$lockdir/${appName}-$id.lock"
    ${flock} -s 9
    finish() {
      ${flock} -u 9
      if ${flock} -xn 9; then ${systemctl} stop "$unit" >/dev/null 2>&1 || true; fi
      exit "$1"
    }

    if ! ${systemctl} start "$unit"; then
      echo "${bin}: could not start $unit (see: journalctl -u '$unit')" >&2
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
      echo "${bin}: the VM did not come up (see: journalctl -u '$unit')" >&2
      finish 1
    fi

    # The guest boots from the host store, so the host's system profile (for the
    # usual CLI tools) is on the guest PATH after the app itself.
    hostsw="$(${co}/readlink -f /run/current-system/sw)"
    guestpath="${cfg.package}/bin:/run/current-system/sw/bin:$hostsw/bin"
    remote="cd $(printf '%q' "$workdir") && export PATH=$(printf '%q' "$guestpath") && exec $(printf '%q ' ${cfg.package}/bin/${bin} "$@")"
    tty=-T
    if [ -t 0 ] && [ -t 1 ]; then tty=-t; fi
    set +e
    ${ssh} "''${ssh_opts[@]}" "$tty" -- "vsock/$cid" "$remote"
    rc=$?
    set -e
    finish "$rc"
  '';

  package = pkgs.runCommand "${appName}-sandbox-vm" { } ''
    mkdir -p $out/bin
    ln -s ${launcher} $out/bin/${bin}
    for d in icons pixmaps; do
      if [ -e ${desktopSource}/share/$d ]; then
        mkdir -p $out/share
        ln -s ${desktopSource}/share/$d $out/share/$d
      fi
    done
    for f in ${desktopSource}/share/applications/*.desktop; do
      [ -e "$f" ] || continue
      mkdir -p $out/share/applications
      ${pkgs.gnused}/bin/sed -E -e '${variants.execExpr bin bin}' -e '/^DBusActivatable=/d' \
        "$f" > "$out/share/applications/$(basename "$f")"
    done
  '';

  # ── Units ────────────────────────────────────────────────────────────────────
  vmmService = {
    description = "Sandbox VM: ${appName}";
    requires = [ (ref "${unit}-prep") ] ++ lib.optional network (ref "${unit}-net");
    after = [ (ref "${unit}-prep") ] ++ lib.optional network (ref "${unit}-net");
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
      # this app's storage/binds (BindPaths, set up by systemd as root) and its
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
      MemoryMax = "${toString (vmCfg.memory + 512)}M";
      MemorySwapMax = 0;
      TasksMax = 1024;
      OOMPolicy = "stop";
    };
  };

  prepService = {
    description = "Sandbox VM keys and runtime dir: ${appName}";
    # Stops (and cleans up) whenever the VM goes down, however it went down.
    bindsTo = [ (ref unit) ];
    restartIfChanged = false;
    stopIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${prepScript}${instArg}";
      ExecStop = "${cleanupScript}${instArg}";
      PrivateNetwork = true;
      ProtectHome = true;
    };
  };

  netService = {
    description = "Sandbox VM network (passt): ${appName}";
    requires = [ (ref "${unit}-prep") ];
    after = [ (ref "${unit}-prep") ];
    bindsTo = [ (ref unit) ];
    restartIfChanged = false;
    stopIfChanged = false;
    serviceConfig = {
      ExecStart = "${netScript}${instArg}";
      User = principal;
      Group = principalGroup;
      # The guest reaches the internet, not the host or anything on the local
      # networks (LAN, tailnet, container/VM bridges). passt makes its outbound
      # connections from this unit, so the cgroup filter applies to all of them.
      IPAddressDeny = [
        "localhost"
        "link-local"
        "multicast"
        "10.0.0.0/8"
        "172.16.0.0/12"
        "192.168.0.0/16"
        "100.64.0.0/10"
        "fc00::/7"
      ];
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
  };

  unsupported =
    lib.optional caps.gpu "gpu"
    ++ lib.optional caps.wayland "wayland"
    ++ lib.optional caps.x11 "x11"
    ++ lib.optional caps.audio "audio"
    ++ lib.optional caps.fido "fido"
    ++ lib.optional (caps.binds.dev != [ ]) "device binds"
    ++ lib.optional (caps.dbus.policies != { }) "D-Bus policies"
    ++ lib.optional (pwdBinds != [ ]) "./-relative binds"
    ++ lib.optional (
      appCfg.nixpakModules != [ ] || cfg.sandbox.nixpakModules != [ ]
    ) "raw nixpakModules (gui, xdg, …)"
    ++ lib.optional (appCfg.variantCommands != { }) "variantCommands";
in
{
  inherit package spec;
  systemConfig = {
    # The /dev/vhost-vsock device crosvm opens.
    boot.kernelModules = [ "vhost_vsock" ];

    # Polkit allowlist (modules/system/sandbox.nix): the user starts/stops only the
    # VM unit; its prep/net units come along as dependencies.
    modules.sandbox.units = lib.optional (!perCwd) "${unit}.service";
    modules.sandbox.unitTemplates = lib.optional perCwd "${unit}@";

    systemd.services = {
      "${unit}${tmpl}" = vmmService;
      "${unit}-prep${tmpl}" = prepService;
    }
    // lib.optionalAttrs network { "${unit}-net${tmpl}" = netService; };

    assertions = [
      {
        assertion = !perCwd || principal == username;
        message = "sandbox app '${appName}': the vm backend attaches the working directory (capabilities.cwd) only when the VM runs as ${username}; a dedicated app uid can't read the user's project.";
      }
      {
        assertion = username == config.modules.sandbox.vm.user;
        message = "sandbox app '${appName}': its user (${username}) differs from the VM guest user (modules.sandbox.vm.user = ${config.modules.sandbox.vm.user}).";
      }
    ];
    warnings =
      lib.optional (cfg.sandbox.mode == "vm" && unsupported != [ ])
        "sandbox app '${appName}' runs in a VM, which doesn't provide these yet (they are ignored): ${lib.concatStringsSep ", " unsupported}.";
  };
}
