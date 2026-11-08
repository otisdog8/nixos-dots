# The minimal kernel for the sandbox VMs' guests: every app VM (lib/vm/guest.nix)
# and the agent VM (lib/vm/agent-guest.nix), on every host
# (modules.sandbox.vm.guestKernel = "minimal", the default; "host" boots the
# host's own kernel instead). The node and sensitive VMs (node-vm.nix) keep the
# host kernel.
#
# Same source and patches as nixpkgs' linux_7_3, with only what these guests
# use: crosvm's virtio-pci machine, the guest's own services, and what the apps
# in it ask of a kernel (namespaces, seccomp, Landlock, 32-bit). What it leaves
# out (netfilter beyond the guest firewall, every hardware driver, sound and
# video beyond a passed-through USB camera, io_uring, AF_ALG, XFRM, MPTCP,
# binder, kexec, BPF LSM, ftrace and kprobes, ...) is unreachable from the apps however
# the guest is set up, which no module blacklist can promise.
#
# How it's built: nixpkgs' own kernel builder (generic.nix), started from
# `make alldefconfig` (every option at its upstream Kconfig default: off for
# drivers and most features, on for the mitigations and hardening) instead of
# x86's defconfig, without nixpkgs' common config (enableCommonConfig = false)
# and without building every other option as a module (autoModules = false).
# So the options below are the whole intent, on top of upstream's defaults.
# Not allnoconfig: that answers no to every question, defaults included, and
# so drops the CPU mitigations, VMAP_STACK, the stack protector, KASLR and IBT.
# The builder checks the result: an option listed here that the final .config
# doesn't have, or has at another value (renamed, dropped, its dependencies
# unmet), fails the build. That is the review on every 7.3.x bump; on a new
# major, also read `make listnewconfig` against this list (new options take
# their defaults). A checked-in .config (linuxManualConfig) would carry
# ~4,000 lines of derived values with no such check.
#
# Hardening (lib/vm/guest-hardening.nix has the runtime side): options with a
# boot-time switch are built at their Kconfig default here, and the switch
# goes on the command line (page_table_check=on and kfence.sample_interval,
# below; slab_nomerge, randomize_kstack_offset, vsyscall=none come from
# hardening.nix's kernelParams, which every profile gets). Build-time-only
# hardening matches what nixpkgs' kernel gave these guests before (randomized
# kmalloc caches, SLS, the schedule() stack-end check, DEBUG_WX), plus
# KSTACK_ERASE and ZERO_CALL_USED_REGS, which have no off switch here.
#
# The nvgpu kmod (lib/vm/nvgpu.nix) is built against this kernel with its Rust
# parsers (NVGPU_RUST=1), so RUST=y, with the kernel derivation's own rustc.
{ lib, pkgs }:
let
  inherit (lib.kernel)
    yes
    no
    module
    freeform
    option
    ;

  config = {
    # --- Base -----------------------------------------------------------
    # Without EXPERT the EXPERT-gated questions stay hidden at their defaults
    # (mostly y); answering it shows them, so the few below (VT, SGETMASK...)
    # can be said no to.
    EXPERT = yes;
    LOCALVERSION = freeform "";
    SMP = yes;
    NR_CPUS = freeform "128";
    HZ_1000 = yes;
    HIGH_RES_TIMERS = yes;
    NO_HZ_IDLE = yes;
    PREEMPT_LAZY = yes;
    PREEMPT_DYNAMIC = yes;
    BINFMT_ELF = yes;
    BINFMT_SCRIPT = yes;
    # Stage 1: every guest boots NixOS's systemd initrd (an initramfs, zstd:
    # boot.initrd.compressor's default), which mounts the root tmpfs and the
    # store's virtiofs (built in) and, in the agent VM, loads btrfs and overlay
    # from itself. Not on by default without nixpkgs' common config.
    BLK_DEV_INITRD = yes;
    RD_ZSTD = yes;
    MODULES = yes;
    MODULE_UNLOAD = yes;
    # The modules are .ko.xz (below): the kernel decompresses them when kmod
    # hands it the file, as on the host.
    MODULE_DECOMPRESS = yes;
    # nixpkgs' module signing, as on the host kernel: modules_install runs
    # kmodigest (common-flags.nix), and the build gathers the per-module
    # certificates into modules.cer (build.nix), which needs one per module.
    MODULE_SIG = yes;
    MODULE_SIG_ALL = yes;
    MODULE_SIG_SHA512 = yes;
    MODULE_SIG_KEY = freeform "";
    SYSTEM_EXTRA_CERTIFICATE = yes;
    SYSTEM_EXTRA_CERTIFICATE_SIZE = freeform (toString (12000 * 260));
    CRYPTO_ECDSA = yes;
    MODULE_COMPRESS = yes;
    MODULE_COMPRESS_XZ = yes;
    MODULE_COMPRESS_ALL = yes;
    IKCONFIG = yes; # /proc/config.gz: what this guest was built with
    IKCONFIG_PROC = yes;
    PRINTK_TIME = yes;
    DEBUG_MISC = option no;
    # Tracing: ftrace, kprobes, uprobes and BPF events stay at their default
    # (off). perf_events stays: x86 selects it (perf_event_paranoid governs it).
    RUST = yes;

    # --- Boot on crosvm ---------------------------------------------------
    # A KVM guest with ACPI (PCI root, power button, the FADT reset register
    # reboot uses), kvmclock, and a 16550 serial console (console=ttyS0).
    # No i8042, CMOS RTC, EFI or PVH (crosvm boots the bzImage directly).
    HYPERVISOR_GUEST = yes;
    PARAVIRT = yes;
    PARAVIRT_SPINLOCKS = yes;
    PARAVIRT_TIME_ACCOUNTING = yes;
    KVM_GUEST = yes;
    X86_X2APIC = yes;
    X86_PAT = yes; # nvgpu's window mappings are WC/UC (else silently UC)
    X86_MCE = no;
    X86_IOPL_IOPERM = no;
    X86_USER_SHADOW_STACK = yes; # as the host's (an opt-in for userspace)
    PERF_EVENTS_INTEL_UNCORE = option no;
    PERF_EVENTS_INTEL_RAPL = option no;
    PERF_EVENTS_INTEL_CSTATE = option no;
    PERF_EVENTS_AMD_UNCORE = option no;
    X86_PLATFORM_DEVICES = no;
    SURFACE_PLATFORMS = option no;
    INTEL_MEI = option no;
    IOMMU_SUPPORT = no; # virtio here goes without an IOMMU
    SUSPEND = no;
    SCHED_MC_PRIO = no; # it selects cpufreq and the P-state drivers
    CPU_FREQ = no;
    THERMAL = option no;
    HWMON = option no;
    POWER_SUPPLY = option no;
    ACPI = yes;
    ACPI_BUTTON = yes; # crosvm powerbtn → logind (evdev) → poweroff
    ACPI_AC = option no;
    ACPI_BATTERY = option no;
    ACPI_PROCESSOR = option no;
    ACPI_DEBUG = option no;
    PNP_DEBUG_MESSAGES = option no;
    CPU_IDLE = yes;
    HALTPOLL_CPUIDLE = yes;
    PCI = yes;
    PCI_MSI = yes;
    PCI_MMCONFIG = yes;
    PCIEASPM = option no;
    VGA_ARB = option no;
    TTY = yes;
    VT = no;
    UNIX98_PTYS = yes; # sshd, tmux
    LEGACY_PTYS = no;
    LEGACY_TIOCSTI = no;
    LDISC_AUTOLOAD = no;
    SERIAL_8250 = yes;
    SERIAL_8250_CONSOLE = yes;
    SERIAL_8250_PCI = no;
    SERIAL_8250_EXAR = option no;
    SERIAL_8250_LPSS = option no;
    SERIAL_8250_MID = option no;
    SERIAL_8250_PERICOM = option no;
    SERIAL_8250_MOXA_PCIE = option no;
    DEVMEM = no;
    DEVPORT = option no;
    BLOCK_LEGACY_AUTOLOAD = no;
    # Input: logind's power key, and HID (FIDO relay, cameras' buttons).
    INPUT = yes;
    INPUT_EVDEV = yes;
    INPUT_KEYBOARD = no;
    INPUT_MOUSE = no;
    INPUT_MOUSEDEV = no;
    SERIO = no;

    # --- virtio --------------------------------------------------------------
    VIRTIO_MENU = yes;
    VIRTIO_PCI = yes;
    VIRTIO_PCI_LEGACY = no;
    VIRTIO_BALLOON = yes; # --balloon-page-reporting (PAGE_REPORTING)
    BLOCK = yes;
    BLK_DEV = yes;
    VIRTIO_BLK = yes; # the agent VM's /persist, the app VMs' swap disk
    NETDEVICES = yes;
    NET_CORE = yes;
    ETHERNET = no;
    WLAN = option no;
    WIRELESS = no;
    USB_NET_DRIVERS = option no;
    PTP_1588_CLOCK = no;
    VIRTIO_NET = yes; # passt, over vhost-user
    HW_RANDOM = yes;
    HW_RANDOM_VIRTIO = yes;
    HW_RANDOM_INTEL = option no;
    HW_RANDOM_AMD = option no;
    HW_RANDOM_VIA = option no;
    VSOCKETS = yes;
    VIRTIO_VSOCKETS = yes; # SSH from the host, the relays
    VSOCKETS_LOOPBACK = no;
    VSOCKETS_DIAG = no;
    FUSE_FS = yes;
    VIRTIO_FS = yes; # the store, the app's data, meta, grants, docs
    DRM = yes;
    DRM_VIRTIO_GPU = yes; # cross-domain Wayland
    DRM_FBDEV_EMULATION = no;
    # nvgpu calls these directly (modpost resolves them only when built in).
    DMA_SHARED_BUFFER = yes;
    SYNC_FILE = yes;

    # --- Storage, swap ----------------------------------------------------
    PARTITION_ADVANCED = yes; # whole-disk btrfs and swap: no partition parsers
    MSDOS_PARTITION = no;
    EFI_PARTITION = no;
    MD = yes;
    BLK_DEV_DM = module; # sbx-swap's plain dm-crypt
    DM_CRYPT = module;
    CRYPTO_XTS = module;
    CRYPTO_AES_NI_INTEL = module;
    CRYPTO_AES = module; # xts(aes) from the AES library, should AES-NI be missing
    SWAP = yes;
    ZSWAP = yes; # zswap.enabled=1 on the swap VMs' command line
    ZSWAP_COMPRESSOR_DEFAULT_ZSTD = yes;
    TRANSPARENT_HUGEPAGE = yes; # madvise; game VMs pass =always
    TRANSPARENT_HUGEPAGE_MADVISE = yes;

    # --- Filesystems ---------------------------------------------------------
    TMPFS = yes;
    TMPFS_POSIX_ACL = yes;
    TMPFS_XATTR = yes;
    DEVTMPFS = yes;
    AUTOFS_FS = yes; # systemd's automounts; the initrd lists autofs
    INOTIFY_USER = yes;
    OVERLAY_FS = module; # the agent VM's /nix/store
    BTRFS_FS = module; # the agent VM's /persist
    BTRFS_FS_POSIX_ACL = yes;
    NETWORK_FILESYSTEMS = no;
    MISC_FILESYSTEMS = no;

    # --- Userspace interfaces ------------------------------------------------
    SYSVIPC = yes; # Xwayland MIT-SHM, Steam, Chromium
    POSIX_MQUEUE = yes;
    KEYS = yes; # 1Password, cryptsetup
    IO_URING = no;
    USERFAULTFD = no;
    SECRETMEM = no;
    SGETMASK_SYSCALL = no;
    CACHESTAT_SYSCALL = no;
    PCSPKR_PLATFORM = no;
    # Steam, Wine (the game VMs share this kernel). ia32_emulation=0 on a VM's
    # command line turns it off there (hardening.nix's ia32Emulation TODO).
    IA32_EMULATION = yes;
    X86_X32_ABI = no;
    MODIFY_LDT_SYSCALL = yes; # Proton, Wine
    X86_16BIT = yes;
    NTSYNC = module; # Wine/Proton (game VMs: modules_load=ntsync)
    UHID = module; # the FIDO relay (fido-guest.py)

    # --- Namespaces, cgroups, systemd ---------------------------------------
    NAMESPACES = yes;
    UTS_NS = yes;
    TIME_NS = yes;
    IPC_NS = yes;
    USER_NS = yes; # bwrap, browsers' sandboxes, nix-daemon builds
    PID_NS = yes;
    NET_NS = yes;
    CGROUPS = yes;
    MEMCG = yes;
    BLK_CGROUP = yes;
    CGROUP_SCHED = yes;
    FAIR_GROUP_SCHED = yes;
    CFS_BANDWIDTH = yes;
    CGROUP_PIDS = yes;
    CPUSETS = yes;
    CGROUP_FREEZER = yes;
    CGROUP_DEVICE = yes;
    CGROUP_CPUACCT = yes;
    CGROUP_BPF = yes; # systemd DeviceAllow, IPAddressDeny, socket filters
    PSI = yes; # systemd-oomd
    BPF_SYSCALL = yes;
    BPF_JIT = yes;
    SECCOMP = yes;
    SECCOMP_FILTER = yes;
    DMIID = yes;
    FHANDLE = yes;

    # --- Security ------------------------------------------------------------
    SECURITY = yes;
    SECURITY_LANDLOCK = yes; # Codex; lsm= is the module's below
    SECURITY_YAMA = yes;
    INTEGRITY = no;
    LSM = freeform "landlock,yama";
    HARDENED_USERCOPY = yes;
    FORTIFY_SOURCE = yes;
    LIST_HARDENED = yes;
    BUG_ON_DATA_CORRUPTION = yes;
    SLAB_FREELIST_RANDOM = yes;
    SLAB_FREELIST_HARDENED = yes;
    SLAB_BUCKETS = yes;
    SHUFFLE_PAGE_ALLOCATOR = yes;
    # init_on_alloc on, as nixpkgs' kernel has it (the guests had it before);
    # init_on_alloc=0 turns it off. init_on_free and slab merging keep their
    # Kconfig defaults (off, on): their switches are on the command line.
    INIT_ON_ALLOC_DEFAULT_ON = yes;
    # No boot-time or runtime switch for these two (kernel.stack_erasing
    # exists only with KSTACK_ERASE_RUNTIME_DISABLE, not set).
    GCC_PLUGINS = yes; # KSTACK_ERASE's instrumentation, with gcc
    KSTACK_ERASE = yes;
    ZERO_CALL_USED_REGS = yes;
    # Built, not enforced: page_table_check=on (the module below).
    PAGE_TABLE_CHECK = yes;
    # Build-time only, as in nixpkgs' kernel (the guests' before this one).
    KMALLOC_PARTITION_CACHES = yes;
    KMALLOC_PARTITION_RANDOM = yes;
    MITIGATION_SLS = yes;
    SCHED_STACK_END_CHECK = yes;
    DEBUG_WX = yes;
    # vm.mmap_min_addr's default, as nixpkgs' kernel has it (the sysctl
    # still overrides it).
    DEFAULT_MMAP_MIN_ADDR = freeform "65536";
    # Built with their upstream defaults (off), switched on the command line
    # (the module below), as the guests had them before: KFENCE's sampling.
    # Lockdown stays available (lockdown=), off as before.
    KFENCE = yes;
    KFENCE_SAMPLE_INTERVAL = freeform "0";
    SECURITY_LOCKDOWN_LSM = yes;
    SECURITY_LOCKDOWN_LSM_EARLY = yes;

    # --- Network -------------------------------------------------------------
    NET = yes;
    UNIX = yes;
    AF_UNIX_OOB = no;
    PACKET = yes; # networkd's DHCP client
    INET = yes;
    IPV6 = yes;
    IPV6_SIT = no;
    SYN_COOKIES = yes;
    MPTCP = no;
    INET_DIAG = no;
    NET_SCHED = yes;
    NET_SCH_FQ_CODEL = yes; # systemd's default_qdisc
    # The guest firewall (networking.firewall, iptables over nf_tables):
    # what its rules ask for, and nothing else.
    NETFILTER = yes;
    NETFILTER_ADVANCED = yes;
    NETFILTER_INGRESS = no;
    NETFILTER_EGRESS = no;
    NF_CONNTRACK = module;
    NF_CT_PROTO_SCTP = no;
    NF_TABLES = module;
    NF_TABLES_INET = yes;
    NF_TABLES_IPV4 = yes;
    NF_TABLES_IPV6 = yes;
    NFT_CT = module;
    NFT_COMPAT = module;
    NETFILTER_XTABLES = module;
    NETFILTER_XT_MATCH_CONNTRACK = module;
    NETFILTER_XT_MATCH_PKTTYPE = module;
    NETFILTER_XT_TARGET_LOG = module;
    IP_NF_IPTABLES = module; # the menu (ip_tables itself is the legacy one's)
    IP_NF_MATCH_RPFILTER = module;
    IP_NF_TARGET_REJECT = module;
    IP6_NF_IPTABLES = module;
    IP6_NF_MATCH_RPFILTER = module;
    IP6_NF_TARGET_REJECT = module;

    # --- Camera passthrough (USB over crosvm's xHCI) --------------------------
    USB_SUPPORT = yes;
    USB = module;
    USB_PCI = yes;
    USB_XHCI_HCD = module;
    USB_XHCI_PCI = module;
    HID_SUPPORT = yes;
    HID = module;
    HIDRAW = yes; # the virtual FIDO key's /dev/hidraw*
    HID_GENERIC = module;
    USB_HID = no;
    I2C_HID = option no;
    MEDIA_SUPPORT = module;
    MEDIA_SUPPORT_FILTER = yes;
    MEDIA_CAMERA_SUPPORT = yes;
    MEDIA_USB_SUPPORT = yes;
    MEDIA_SUBDRV_AUTOSELECT = no;
    USB_VIDEO_CLASS = module;
    USB_VIDEO_CLASS_INPUT_EVDEV = no;
    SOUND = module;
    SND = module;
    SND_USB = yes;
    SND_USB_AUDIO = module; # the camera's microphone
    SND_DRIVERS = no;
    SND_PCI = no;
    SND_X86 = option no;
    SND_VERBOSE_PROCFS = no;
  };

  kernel = pkgs.linux_7_3.override {
    pname = "linux-sbx-guest";
    defconfig = "alldefconfig";
    enableCommonConfig = false;
    autoModules = false;
    ignoreConfigErrors = false;
    structuredExtraConfig = config;
  };
in
{
  inherit kernel;
  kernelPackages = pkgs.linuxPackagesFor kernel;

  # For a guest booting it (sandbox-vm.nix and agent-vm.nix add it to the
  # guest's modules).
  module = {
    # nixpkgs' default initrd modules (SATA, NVMe, USB HID, i8042...) and the
    # ones its own modules name that this kernel doesn't have: the initrd
    # build would fail on each.
    boot.initrd.includeDefaultModules = false;
    boot.initrd.availableKernelModules.efivarfs = lib.mkForce false;
    # No TPM in crosvm's machine, nor its drivers here (tpm-tis, tpm-crb).
    boot.initrd.systemd.tpm2.enable = lib.mkDefault false;
    systemd.tpm2.enable = lib.mkDefault false;
    # Stage 2's default (kernel.nix): no loop device here. (atkbd:
    # guest-hardening.nix, for either kernel.)
    boot.kernelModules.loop = lib.mkForce false;
    # Page table checks (double mappings, refcount slips) and KFENCE's
    # sampling at nixpkgs' interval (100 ms), both built in above; their
    # switches are the command line's, as the hardening's others are.
    boot.kernelParams = [
      "page_table_check=on"
      "kfence.sample_interval=100"
    ];
    # Sysctls of what this kernel leaves out (io_uring, kexec, MPTCP; SysRq,
    # which systemd's own 50-default.conf still sets, so one warning stays):
    # hardening.nix leaves them unset rather than have systemd-sysctl warn
    # about each at boot (kexec_load_disabled here also leaves
    # protectKernelImage off).
    modules.system.hardening.skipSysctls = [
      "kernel.io_uring_disabled"
      "kernel.io_uring_group"
      "kernel.kexec_load_disabled"
      "kernel.sysrq"
      "net.mptcp.enabled"
    ];
    # NixOS always appends bpf to lsm=; this kernel has no BPF LSM, so the
    # guest asks for the two it has.
    security.lsm = lib.mkForce [
      "landlock"
      "yama"
    ];
  };
}
