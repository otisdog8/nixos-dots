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
  ];

  mkInstallFalse = mods: lib.concatMapStringsSep "\n" (m: "install ${m} /bin/false") mods;

  # Sit between NixOS's mkDefault (1000) and a normal value (100): wins over
  # upstream defaults but per-host overrides via bare value or lib.mkForce
  # still take precedence.
  hardenSysctls = lib.mapAttrs (_: lib.mkOverride 900);
in
{
  options.modules.system.hardening = {
    enable = lib.mkEnableOption "system hardening baseline";

    profile = lib.mkOption {
      type = lib.types.enum [
        "workstation"
        "server"
        "k3s-node"
      ];
      default = "workstation";
      description = "Profile that adjusts toggle defaults; finer knobs below still win.";
    };

    ipForward = lib.mkOption {
      type = lib.types.bool;
      default = cfg.profile == "k3s-node";
      description = "Enable net.ipv4.ip_forward. Required for K3s/CNI and routers.";
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

    hardenMounts = lib.mkOption {
      type = lib.types.bool;
      default = cfg.profile != "k3s-node";
      description = "Enable /tmp on tmpfs (nosuid,nodev). Off by default for k3s nodes.";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernel.sysctl = lib.mkMerge [
      (hardenSysctls {
        # Restrict kernel pointer/log exposure
        "kernel.kptr_restrict" = 2;
        "kernel.dmesg_restrict" = 1;
        "kernel.printk" = "3 3 3 3";

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
        "net.ipv4.conf.all.rp_filter" = 1;
        "net.ipv4.conf.default.rp_filter" = 1;
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
      })

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
      "init_on_alloc=1"
      "init_on_free=1"
      "page_alloc.shuffle=1"

      # Stack offset randomisation on syscall entry
      "randomize_kstack_offset=on"

      # Disable obsolete/dangerous interfaces
      "vsyscall=none"
      "debugfs=off"
    ];

    boot.blacklistedKernelModules =
      lib.optionals cfg.blacklistFs fsModules
      ++ lib.optionals cfg.blacklistNet netModules;

    # Defense in depth alongside blacklistedKernelModules — matches the existing
    # install-bin pattern in modules/system/kernel.nix for esp4/esp6/rxrpc.
    boot.extraModprobeConfig =
      lib.optionalString cfg.blacklistFs (mkInstallFalse fsModules + "\n")
      + lib.optionalString cfg.blacklistNet (mkInstallFalse netModules + "\n");

    # Kernel image / page table protections
    security.protectKernelImage = lib.mkDefault true;
    security.forcePageTableIsolation = lib.mkDefault true;
    # security.lockKernelModules intentionally left default (false) so DKMS
    # modules (nvidia, openrazer, virtualbox) can still load at runtime.

    # Tighter umask for newly created system files / new accounts.
    security.loginDefs.settings.UMASK = lib.mkDefault "027";

    # 4-second delay after a failed local login (mitigates brute force at console)
    security.pam.services.login.failDelay = {
      enable = lib.mkDefault true;
      delay = lib.mkDefault 4000000;
    };

    # Mount-option hardening: tmpfs /tmp gets nosuid,nodev automatically via
    # systemd's tmp.mount. Intentionally NOT noexec (Steam/Wine/PyCharm break).
    boot.tmp = lib.mkIf cfg.hardenMounts {
      useTmpfs = lib.mkDefault true;
      tmpfsSize = lib.mkDefault "50%";
    };
  };
}
