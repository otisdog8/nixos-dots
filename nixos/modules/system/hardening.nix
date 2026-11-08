# System hardening baseline (sysctl, kernel params, module blacklist,
# mount-option, PAM/login). Per-host opt-in via modules.system.hardening.enable.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.system.hardening;

  fsModules = [
    "cramfs"
    "freevxfs"
    "jffs2"
    "hfs"
    "hfsplus"
    "udf"
    # Exotic / legacy filesystems autoloaded by mount(8) via the fs alias.
    "jfs"
    "ufs"
    "efs"
    "befs"
    "affs"
    "adfs"
    "omfs"
    "qnx4"
    "qnx6"
    "hpfs"
    "bfs"
    "minix"
    "gfs2"
    "ocfs2"
    "nilfs2"
    "coda"
    # In-kernel NTFS read/write driver. Userspace ntfs-3g (FUSE) still works
    # if added to environment.systemPackages; this only blocks the kernel
    # driver's auto-load on external-drive insert.
    "ntfs3"
  ];

  netModules = [
    "dccp"
    "sctp"
    "rds"
    "tipc"
    "ax25"
    "netrom"
    "rose"
    "firewire-core"
    "firewire-ohci"
    "firewire-sbp2"
    "ohci1394"
    # FireWire siblings (DMA-attack surface, defense in depth alongside the
    # blacklisted core/ohci modules).
    "firewire-net"
    "dv1394"
    "raw1394"
    "video1394"
    # Rare socket families autoloadable via socket(AF_*). Same attack class
    # as Copy Fail (CVE-2026-31431) and Dirty Frag (CVE-2026-43284 / -43500):
    # unprivileged socket() triggers in-kernel request_module().
    "appletalk"
    "x25"
    "llc2"
    "can"
    "atm"
    "kcm"
    "phonet"
    "nfc"
    "caif_socket"
    "ieee802154_socket"
    "af_802154"
    "smc"
    "qrtr"
    # Removed-from-upstream AF families. Modprobe alias resolution is a
    # no-op, but keeping these documented protects against future revival.
    "ipx"
    "decnet"
    "econet"
    # LLC encapsulation modules (legacy, autoloaded by old net stacks).
    "p8022"
    "p8023"
    "psnap"
    # Diag-socket and transport siblings of protocols already blocked above.
    "tipc_diag"
    "sctp_diag"
    "rds_rdma"
    "rds_tcp"
    # ATM USB modems (defense in depth — ATM core is blocked above).
    "ueagle-atm"
    "usbatm"
    "xusbatm"
    # Full CAN-bus family. The core "can" module above blocks socket(AF_CAN),
    # but specific protocol/driver modules also expose attack surface.
    "can-bcm"
    "can-raw"
    "can-gw"
    "can-isotp"
    "can-j1939"
    "can-dev"
    "c_can"
    "m_can"
    "vcan"
    "vxcan"
    # AF_PPPOX (net-pf-24) family — PPPoE, PPTP-GRE, and PPPoL2TP all hang
    # off pppox. Blocking pppox closes the whole family in one stroke; the
    # individual modules are listed too as belt-and-suspenders.
    "pppox"
    "pppoe"
    "pptp"
    # L2TP — l2tp_core is the base; blocking it kills l2tp_ppp / l2tp_eth /
    # l2tp_ip{,6} / l2tp_netlink. Reachable via socket(AF_PPPOX, _, PX_PROTO_OL2TP).
    "l2tp_core"
    "l2tp_ppp"
    "l2tp_eth"
    "l2tp_ip"
    "l2tp_ip6"
    "l2tp_netlink"
  ];

  ttyModules = [
    # TTY line discipline modules autoloaded via the TIOCSETD ioctl.
    # CVE-2017-2636 was a local-root via n_hdlc reached this way.
    "n_hdlc"
    "n_gsm"
    "mkiss"
    "6pack"
    "slcan"
    "can327"
    "slip"
  ];

  afAlgModules = [
    # AF_ALG userspace crypto API (net-pf-38). Blocking af_alg subsumes the
    # algif_* algorithm providers — algif_aead (Copy Fail), algif_hash,
    # algif_skcipher, algif_rng. Breaks bluez/libell crypto (AES-CMAC,
    # AES-CCM, P-256 ECDH), so Bluetooth pairing will not work on hosts
    # where this is enabled.
    "af_alg"
  ];

  miscModules = [
    # V4L Virtual Video Test Driver — chained for root in Pwn2Own 2020
    # (CVE-2019-18683 + uvcvideo). Autoloads via /dev/videoN open. No
    # legitimate use outside V4L kernel development.
    "vivid"
    # Floppy controller. No hardware on any host here; module has had
    # historical UAF/race bugs. Autoloads when /dev/fd* is opened.
    "floppy"
  ];

  mkInstallFalse = mods: lib.concatMapStringsSep "\n" (m: "install ${m} /bin/false") mods;
  isGuest = cfg.profile == "vm-guest";
  isK3s = cfg.profile == "k3s-node";

  nodeVmGuest = config.modules.system.nodeVmGuest.enable or false;

  # devices/global_filter for lvm.conf, or null to leave it alone. Hosts with
  # LVM (the *-hv machines) have their PV on the root LUKS mapper
  # (cryptarquitens...), and accept that alone: the node VMs' disks are LVs
  # on it, and what a guest writes inside them (Ceph's LVM) stays the
  # guest's. Hosts without LVM accept nothing. The k3s roles are left alone:
  # the bare-metal nodes' Ceph OSDs are ceph-volume LVM on the host, the node
  # VMs' are on their passthrough disk, and k3s-sensitive.nix sets its own.
  hasLvm = (config.disko.devices.lvm_vg or { }) != { };
  lvmFilter =
    let
      accept = map (n: ''"a|^/dev/mapper/${n}$|"'') (lib.attrNames config.boot.initrd.luks.devices);
    in
    if isK3s then
      null
    # A rescue stick: every PV visible, none activated unasked (an empty
    # auto-activation list stops -aay, udev's and the boot's); `vgchange -ay`
    # still works.
    else if cfg.lvmRescue then
      ''
        activation/auto_activation_volume_list = [ ]
      ''
    else
      ''
        devices/global_filter = [ ${lib.concatStringsSep " " (lib.optionals hasLvm accept ++ [ ''"r|.*|"'' ])} ]
      '';

  # Sit between NixOS's mkDefault (1000) and a normal value (100): wins over
  # upstream defaults but per-host overrides via bare value or lib.mkForce
  # still take precedence.
  # Ones the kernel lacks (skipSysctls) are left out.
  hardenSysctls = attrs: lib.mapAttrs (_: lib.mkOverride 900) (removeAttrs attrs cfg.skipSysctls);
in
{
  options.modules.system.hardening = {
    enable = lib.mkEnableOption "system hardening baseline";

    profile = lib.mkOption {
      type = lib.types.enum [
        "workstation"
        "server"
        "k3s-node"
        # The crosvm app and agent VMs (lib/vm/guest.nix, agent-guest.nix).
        "vm-guest"
      ];
      default = "workstation";
      description = "Profile that adjusts toggle defaults; finer knobs below still win.";
    };

    ia32Emulation = lib.mkOption {
      type = lib.types.bool;
      # Workstations need 32-bit for Steam, Proton and Wine, and so do the
      # game VMs (one guest system serves every app VM).
      # TODO: per-VM ia32_emulation=0 (instance.nix guestKernelParams) for
      # app VMs without Steam/Wine, and for the agent VM once nothing there
      # builds i686.
      default = cfg.profile == "workstation" || isGuest;
      description = ''
        Keep the 32-bit syscall ABI. Off (ia32_emulation=0), the compat
        syscall table and every compat ioctl/setsockopt path are gone, and
        32-bit binaries don't run: a local nix build of an i686 derivation
        fails there too.
      '';
    };

    ipForward = lib.mkOption {
      type = lib.types.bool;
      default = !isGuest;
      description = ''
        Enable net.ipv4.ip_forward. Required for K3s/CNI, routers, and any
        host that may act as a Tailscale exit node or subnet router. On by
        default since most hosts here should be exit-node-capable. Off in
        the VM guests, which route nothing.
      '';
    };

    allowUserns = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Allow unprivileged user namespaces (needed for chromium/bwrap/flatpak/podman).";
    };

    blacklistFs = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Blacklist obscure filesystem kernel modules.";
    };

    blacklistNet = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Blacklist obscure network protocol and firewire kernel modules.";
    };

    blacklistTty = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Blacklist TTY line discipline kernel modules autoloadable via the
        TIOCSETD ioctl (the CVE-2017-2636 n_hdlc class).
      '';
    };

    blacklistAfAlg = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Blacklist the AF_ALG userspace crypto socket family. Closes the
        attack surface that produced Copy Fail (CVE-2026-31431). Breaks
        bluez Bluetooth pairing because libell does AES-CMAC / AES-CCM /
        P-256 ECDH through AF_ALG. Off by default; opt in per host where
        Bluetooth is unused (or accepted as broken).
      '';
    };

    blacklistMisc = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Blacklist obscure hardware/test kernel modules that autoload on
        device access (vivid V4L test driver, floppy controller).
      '';
    };

    skipSysctls = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "kernel.io_uring_disabled"
        "kernel.io_uring_group"
        "net.mptcp.enabled"
        "kernel.kexec_load_disabled"
      ];
      description = ''
        Sysctls this host's kernel doesn't have (a minimal guest kernel
        without io_uring, MPTCP or kexec): left out instead of failing to
        write at boot. kernel.kexec_load_disabled here also leaves
        security.protectKernelImage off.
      '';
    };

    lvmRescue = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        A rescue system (liveusb): LVM sees every PV, so `vgchange -ay` can
        bring up another host's volumes, but nothing is activated on its own.
      '';
    };

    debugfs = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Leave debugfs available (no debugfs=off). It exposes kernel internals
        to root; the node-VM hypervisors keep it for scheduler tuning
        (/sys/kernel/debug/sched).
      '';
    };

    zeroMemory = lib.mkOption {
      type = lib.types.bool;
      default = !isGuest;
      description = ''
        Zero memory on every allocation and free (init_on_alloc=1,
        init_on_free=1): no stale data in fresh pages, at a CPU cost that
        grows with allocation churn (JVMs, databases, the page cache). Off on
        the node VMs, whose CPU is the scarce resource (node-vm.nix), and
        in the app and agent VMs for the same reason (games, JVMs, builds).
      '';
    };

    hardenMounts = lib.mkOption {
      type = lib.types.bool;
      default = cfg.profile != "k3s-node" && !isGuest;
      description = "Enable /tmp on tmpfs (nosuid,nodev). Off by default for k3s nodes and VM guests (whose / is a tmpfs).";
    };

    preferSystemBinaries = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Order the user's writable Nix profiles (~/.nix-profile, the per-user
        profile) AFTER the system profiles on PATH, instead of before. Closes
        the shadowing vector where `nix profile install <trojan-git>` overrides
        a system command like git/ssh/kubectl for the session.

        Setuid tooling (sudo, mount, su) is unaffected either way — those live
        in /run/wrappers/bin, which is prepended separately and stays first.

        Tradeoff: this inverts the normal "user profile overrides system"
        convention, so a package you `nix profile install` will no longer take
        precedence over a same-named system package. It also pins the profile
        list with mkForce, so if a future nixpkgs adds a new default profile dir
        it won't be on PATH until this list is updated. Off by default; the
        benefit is modest here since the user profile is not persisted (wiped
        each boot) and an in-session attacker has stronger options anyway.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernel.sysctl = lib.mkMerge [
      (hardenSysctls {
        # Restrict kernel pointer/log exposure. No kernel.printk clamp here:
        # it silenced the netconsole feed fleet-wide (netconsole.nix now sets
        # "5 4 1 7" on senders), and its security value was marginal anyway —
        # dmesg_restrict already gates log reading, and the quiet console
        # comes from kernel.nix's cmdline (consoleLogLevel/quiet), not this
        # runtime sysctl.
        "kernel.kptr_restrict" = 2;
        "kernel.dmesg_restrict" = 1;

        # Restrict tracing/profiling/BPF surface
        "kernel.yama.ptrace_scope" = 1;
        "kernel.perf_event_paranoid" = 3;
        "kernel.unprivileged_bpf_disabled" = 1;
        "net.core.bpf_jit_harden" = 2;

        # (kernel.kexec_load_disabled is set by security.protectKernelImage)

        # ASLR + oops behaviour
        "kernel.randomize_va_space" = 2;
        "kernel.panic_on_oops" = 1;

        # Filesystem link/fifo/regular file protections (mitigate TOCTOU + spoof)
        "fs.protected_hardlinks" = 1;
        "fs.protected_symlinks" = 1;
        "fs.protected_fifos" = 2;
        "fs.protected_regular" = 2;

        # IPv4 network stack hardening
        "net.ipv4.tcp_syncookies" = 1;
        "net.ipv4.tcp_rfc1337" = 1;
        # rp_filter=2 (loose, RFC 3704) + src_valid_mark=1 makes the
        # reverse-path check honour fwmark-based policy routing — required
        # for asymmetric layouts (Tailscale exit nodes, Cilium overlay,
        # any layered WireGuard). Strict (=1) would silently drop their
        # return traffic. Matches networking.firewall.checkReversePath="loose".
        "net.ipv4.conf.all.rp_filter" = 2;
        "net.ipv4.conf.default.rp_filter" = 2;
        "net.ipv4.conf.all.src_valid_mark" = 1;
        "net.ipv4.conf.default.src_valid_mark" = 1;
        "net.ipv4.conf.all.log_martians" = 1;
        "net.ipv4.conf.default.log_martians" = 1;
        "net.ipv4.conf.all.accept_redirects" = 0;
        "net.ipv4.conf.default.accept_redirects" = 0;
        "net.ipv4.conf.all.secure_redirects" = 0;
        "net.ipv4.conf.default.secure_redirects" = 0;
        "net.ipv4.conf.all.send_redirects" = 0;
        "net.ipv4.conf.default.send_redirects" = 0;
        "net.ipv4.conf.all.accept_source_route" = 0;
        "net.ipv4.conf.default.accept_source_route" = 0;
        "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
        "net.ipv4.icmp_ignore_bogus_error_responses" = 1;

        # IPv6 stack hardening (intentionally keep accept_ra for SLAAC at home)
        "net.ipv6.conf.all.accept_redirects" = 0;
        "net.ipv6.conf.default.accept_redirects" = 0;
        "net.ipv6.conf.all.accept_source_route" = 0;
        "net.ipv6.conf.default.accept_source_route" = 0;

        # io_uring only for root (CAP_SYS_ADMIN) and the io_uring group, which
        # has no members: a service that ever needs it joins the group.
        # Nothing here does (crosvm's executor is epoll, Ceph's bluestore uses
        # libaio, Postgres' io_method defaults to worker); the sandboxes'
        # seccomp filter already refuses it (lib/backends/bwrap-syscalls.nix).
        "kernel.io_uring_disabled" = 1;
        "kernel.io_uring_group" = config.users.groups.io_uring.gid;

        # Line disciplines (TIOCSETD) load for root only: the n_hdlc/n_gsm
        # LPE class, reachable from any pty, sandboxes included.
        "dev.tty.ldisc_autoload" = 0;

        # No MPTCP. Go >= 1.24 listeners open MPTCP sockets by default and
        # fall back to TCP. Per network namespace: pods and other namespaces
        # start at 1 whatever this says.
        "net.mptcp.enabled" = 0;
      })

      # kernel.nix's, which the guests don't import. No keyboard in a VM, so no
      # SysRq at all.
      (lib.mkIf isGuest (hardenSysctls {
        "kernel.sysrq" = 0;
        "fs.suid_dumpable" = 0;
        "dev.tty.legacy_tiocsti" = 0;
      }))

      # Reboot 10s after a panic instead of hanging (panic_on_oops=1 above,
      # and softdog can't fire after panic()). Not in VMs: they boot with
      # panic=-1, which this sysctl would override.
      (lib.mkIf (cfg.profile == "server" || (isK3s && !nodeVmGuest)) (hardenSysctls {
        "kernel.panic" = 10;
      }))

      (lib.mkIf (!cfg.allowUserns) (hardenSysctls {
        "kernel.unprivileged_userns_clone" = 0;
      }))

      (lib.mkIf cfg.ipForward (hardenSysctls {
        "net.ipv4.ip_forward" = 1;
      }))
    ];

    boot.kernelParams = [
      # Heap/page hardening
      "slab_nomerge"
      "page_alloc.shuffle=1"

      # Stack offset randomisation on syscall entry
      "randomize_kstack_offset=on"

      # Disable obsolete/dangerous interfaces
      "vsyscall=none"

      # No writes to a block device a filesystem has mounted (the
      # crafted-image-under-a-live-mount class). Breaks dd, tune2fs, e2label
      # and offline-style fsck on mounted filesystems; test recusant's
      # bcachefs tools (fsck, set-option on the mounted fs) first.
      "bdev_allow_write_mounted=0"
    ]
    # No IOMMU params, on purpose. The AMD hosts run AMD-Vi in the kernel's
    # default lazy mode (CONFIG_IOMMU_DEFAULT_DMA_LAZY=y); strict
    # (iommu.strict=1) would close the short window in which a device can
    # still DMA into a just-unmapped buffer, at some I/O cost. Plain USB
    # devices can't DMA at all (the host controller does); the DMA-capable
    # external paths are Thunderbolt/USB4 PCIe tunnels (authorized per the
    # thunderbolt security level) and FireWire (blocked, netModules).
    # TODO: constitution is Intel, and CONFIG_INTEL_IOMMU_DEFAULT_ON is unset,
    # so its VT-d is there but off; consider intel_iommu=on there (and on
    # liveusb).
    ++ lib.optional (!cfg.ia32Emulation) "ia32_emulation=0"
    ++ lib.optional (!cfg.debugfs) "debugfs=off"
    ++ lib.optionals cfg.zeroMemory [
      "init_on_alloc=1"
      "init_on_free=1"
    ];

    boot.blacklistedKernelModules =
      lib.optionals cfg.blacklistFs fsModules
      ++ lib.optionals cfg.blacklistNet netModules
      ++ lib.optionals cfg.blacklistTty ttyModules
      ++ lib.optionals cfg.blacklistAfAlg afAlgModules
      ++ lib.optionals cfg.blacklistMisc miscModules;

    # Defense in depth alongside blacklistedKernelModules — matches the existing
    # install-bin pattern in modules/system/kernel.nix for esp4/esp6/rxrpc.
    boot.extraModprobeConfig =
      lib.optionalString cfg.blacklistFs (mkInstallFalse fsModules + "\n")
      + lib.optionalString cfg.blacklistNet (mkInstallFalse netModules + "\n")
      + lib.optionalString cfg.blacklistTty (mkInstallFalse ttyModules + "\n")
      + lib.optionalString cfg.blacklistAfAlg (mkInstallFalse afAlgModules + "\n")
      + lib.optionalString cfg.blacklistMisc (mkInstallFalse miscModules + "\n");

    # LVM activates only this host's own PVs: a hotplugged or loop-attached
    # PV, or one a VM wrote inside the disk it was given, would otherwise
    # make root activate dm-thin/cache/raid/integrity targets parsing its
    # metadata. In the initrd too (its lvm.conf is separate). services.lvm
    # stays on: it carries the dm udev rules cryptsetup needs.
    environment.etc."lvm/lvm.conf".text = lib.mkIf (lvmFilter != null) lvmFilter;
    boot.initrd.systemd.contents = lib.mkIf (lvmFilter != null) {
      "/etc/lvm/lvm.conf".text = lvmFilter;
    };

    # Without the 32-bit ABI nothing i686 runs: Nix stops offering to build
    # it (its default extra-platforms is i686-linux on x86_64), and no 32-bit
    # graphics drivers (nixos-hardware's GPU modules turn them on).
    nix.settings.extra-platforms = lib.mkIf (!cfg.ia32Emulation && config.nix.enable) [ ];
    hardware.graphics.enable32Bit = lib.mkIf (!cfg.ia32Emulation) (lib.mkForce false);

    # The io_uring sysctl's group. A fixed gid (unused by nixpkgs' ids.nix,
    # below the dynamic 400-999 range), since sysctl.d needs the number.
    users.groups.io_uring.gid = 390;

    # /dev/kvm and vhost: root:kvm 0660 instead of systemd's 0666, so a local
    # uid or a sandbox can't reach KVM or vhost. Every opener has the group:
    # the VMM units and nvgpu backends as SupplementaryGroups=kvm
    # (lib/vm/core/hardening.nix), jrt as a member (nixos/default.nix, and so
    # claude-nesbox), and below libvirt's QEMU and nix's build users. /dev/vfio/vfio to root alone (vfio is blocked anyway).
    services.udev.extraRules = ''
      KERNEL=="kvm", GROUP="kvm", MODE="0660", OPTIONS+="static_node=kvm"
      KERNEL=="vhost-net", GROUP="kvm", MODE="0660", OPTIONS+="static_node=vhost-net"
      KERNEL=="vhost-vsock", GROUP="kvm", MODE="0660", OPTIONS+="static_node=vhost-vsock"
      KERNEL=="vfio", GROUP="root", MODE="0600", OPTIONS+="static_node=vfio/vfio"
    '';
    users.users = lib.mkMerge [
      # libvirt's guests run as qemu-libvirtd (virt.nix), which nixpkgs doesn't
      # put in kvm.
      (lib.mkIf (
        config.virtualisation.libvirtd.enable && !config.virtualisation.libvirtd.qemu.runAsRoot
      ) { qemu-libvirtd.extraGroups = [ "kvm" ]; })
      # Builds that require the kvm feature (NixOS VM tests) get /dev/kvm in
      # their sandbox, and run as these users, with their supplementary groups.
      (lib.mkIf (config.nix.enable && !isGuest && !(config.nix.settings.auto-allocate-uids or false)) (
        lib.genAttrs (map (n: "nixbld${toString n}") (lib.range 1 config.nix.nrBuildUsers)) (_: {
          extraGroups = [ "kvm" ];
        })
      ))
    ];

    # Kernel image / page table protections
    security.protectKernelImage = lib.mkDefault (!lib.elem "kernel.kexec_load_disabled" cfg.skipSysctls);
    # Not forced in a guest: the kernel turns PTI on itself where the CPU is
    # vulnerable, and forcing it on the AMD hosts' guests only costs syscalls.
    security.forcePageTableIsolation = lib.mkDefault (!isGuest);
    # security.lockKernelModules intentionally left default (false) so DKMS
    # modules (nvidia, openrazer, virtualbox) can still load at runtime.

    # Tighter umask for newly created system files / new accounts.
    security.loginDefs.settings.UMASK = lib.mkDefault "027";

    # 4-second delay after a failed local login (mitigates brute force at console)
    security.pam.services.login.failDelay = {
      enable = lib.mkDefault true;
      delay = lib.mkDefault 4000000;
    };

    # Reorder PATH so user-writable profiles lose to system profiles. The
    # wrappers dir (/run/wrappers/bin, setuid sudo) is added separately with a
    # higher priority and is NOT part of environment.profiles, so it remains
    # first regardless. Mirrors the current nixpkgs default set, reversed.
    environment.profiles = lib.mkIf cfg.preferSystemBinaries (
      lib.mkForce [
        "/run/current-system/sw"
        "/nix/var/nix/profiles/default"
        "/etc/profiles/per-user/$USER"
        "$HOME/.nix-profile"
        "/nix/profile"
        "$HOME/.local/state/nix/profile"
      ]
    );

    # Mount-option hardening: tmpfs /tmp gets nosuid,nodev automatically via
    # systemd's tmp.mount. Intentionally NOT noexec (Steam/Wine/PyCharm break).
    boot.tmp = lib.mkIf cfg.hardenMounts {
      useTmpfs = lib.mkDefault true;
      tmpfsSize = lib.mkDefault "50%";
    };
  };
}
