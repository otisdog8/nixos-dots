# systemd sandboxing shared by VM units.
{
  # Processes that build their own jail (crosvm and its device processes):
  # user/pid/mount/net namespaces, pivot_root into empty roots, seccomp. Those
  # namespace types, the mount syscalls and seccomp itself must stay available.
  # Never deny @privileged as a group: pivot_root is in it.
  jailedSyscallFilter = [
    "@system-service"
    "@mount"
    "@sandbox"
    "~@obsolete @raw-io @reboot @swap @module @cpu-emulation @debug @clock"
  ];

  # The VMM's own network namespace (PrivateNetwork) must leave vsock global:
  # with per-namespace vsock (net.vsock.ns_mode, Linux 7.x) in "local" mode, the
  # guest's CID would only be reachable from inside that namespace, so the
  # host's SSH and relays couldn't reach it. Namespaces start in their parent's
  # child_ns_mode ("global" by default); checked at start rather than assumed.
  vsockNsCheck = ''
    if [ -r /proc/sys/net/vsock/ns_mode ] && [ "$(< /proc/sys/net/vsock/ns_mode)" != global ]; then
      echo "vsock is per-namespace here (net.vsock.ns_mode=$(< /proc/sys/net/vsock/ns_mode)): the VM would be unreachable from the host; set net.vsock.child_ns_mode=global" >&2
      exit 1
    fi
  '';

  # A root step (the VM's prep and cleanup, GPU socket handover, cameras, core
  # scheduling: lib/vm/root.py). Never a "+" Exec line: a unit of its own, as
  # root but bounded to `caps`, the host read-only (the unit names the one
  # runtime dir it may write), no home, no network. The unit adds what it must
  # leave open (devices, /sys, mount syscalls).
  rootStep = caps: {
    CapabilityBoundingSet = caps;
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateIPC = true;
    PrivateNetwork = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    RestrictNamespaces = true;
    LockPersonality = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    MemoryDenyWriteExecute = true;
    RestrictAddressFamilies = [ "AF_UNIX" ];
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" ];
    SystemCallErrorNumber = "EPERM";
    KeyringMode = "private";
    UMask = "0077";
    LimitCORE = 0;
  };

  # A host unit of an app VM that isn't root (lib/vm/instance.nix): the few
  # that must stay the desktop user's (display, session bus, documents, the
  # grants hub) and the VM's own uid's (relay, capture adapter, grants share,
  # cross-domain GPU). No capabilities, the host read-only and no home, no
  # network, no other process (a pid namespace of its own), no namespaces,
  # @system-service, no W+X memory. The unit adds the paths it may see
  # (instance.nix `view`) and opens what it must, each deviation said there:
  # devices, address families, a jail's namespaces and syscalls
  # (jailedSyscallFilter), ProcSubset (minijail and bwrap read /proc/sys),
  # PrivateUsers=self (where no ACL, /proc lookup or D-Bus check needs the
  # real ids).
  # As PID 1 of its pid namespace a process never gets a signal it has no
  # handler for from outside it, SIGTERM included, so these stop with SIGKILL:
  # none of them needs a graceful stop.
  userStep = {
    NoNewPrivileges = true;
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    ProtectSystem = "strict";
    ProtectHome = "tmpfs";
    PrivateTmp = true;
    PrivateIPC = true;
    PrivateDevices = true;
    PrivateNetwork = true;
    IPAddressDeny = "any";
    PrivatePIDs = true;
    KillSignal = "SIGKILL";
    ProtectProc = "invisible";
    ProcSubset = "pid";
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
    MemoryDenyWriteExecute = true;
    RestrictAddressFamilies = [ "AF_UNIX" ];
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" ];
    SystemCallErrorNumber = "EPERM";
    KeyringMode = "private";
    UMask = "0077";
    LimitCORE = 0;
  };

  # The VMM (crosvm run). The unit adds what's per-VM: ExecStart, User/Group,
  # SystemCallFilter (jailedSyscallFilter + extras), the paths it may see,
  # DeviceAllow, MemoryMax.
  vmm = {
    SupplementaryGroups = [ "kvm" ];
    NoNewPrivileges = true;
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    RestrictNamespaces = "user pid mnt net";
    SystemCallArchitectures = "native";
    SystemCallErrorNumber = "EPERM";
    LockPersonality = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    MemoryDenyWriteExecute = true;
    ProtectSystem = "strict";
    ProtectHome = "tmpfs";
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
    # No IP at all: the guest's network (if any) is passt, over a unix socket.
    # Its own network namespace too, so not even the host's abstract unix
    # sockets are reachable before crosvm jails its devices (see vsockNsCheck).
    PrivateNetwork = true;
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_NETLINK"
    ];
    IPAddressDeny = "any";
    LimitCORE = 0;
    MemorySwapMax = 0;
    TasksMax = 1024;
    OOMPolicy = "stop";
  };
}
