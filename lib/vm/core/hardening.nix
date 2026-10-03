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
