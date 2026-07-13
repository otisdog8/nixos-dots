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
      default = true;
      description = ''
        Enable net.ipv4.ip_forward. Required for K3s/CNI, routers, and any
        host that may act as a Tailscale exit node or subnet router. On by
        default since most hosts here should be exit-node-capable.
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

    hardenMounts = lib.mkOption {
      type = lib.types.bool;
      default = cfg.profile != "k3s-node";
      description = "Enable /tmp on tmpfs (nosuid,nodev). Off by default for k3s nodes.";
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

    # Reorder PATH so user-writable profiles lose to system profiles. The
    # wrappers dir (/run/wrappers/bin, setuid sudo) is added separately with a
    # higher priority and is NOT part of environment.profiles, so it remains
    # first regardless. Mirrors the current nixpkgs default set, reversed.
    environment.profiles = lib.mkIf cfg.preferSystemBinaries (lib.mkForce [
      "/run/current-system/sw"
      "/nix/var/nix/profiles/default"
      "/etc/profiles/per-user/$USER"
      "$HOME/.nix-profile"
      "/nix/profile"
      "$HOME/.local/state/nix/profile"
    ]);

    # Mount-option hardening: tmpfs /tmp gets nosuid,nodev automatically via
    # systemd's tmp.mount. Intentionally NOT noexec (Steam/Wine/PyCharm break).
    boot.tmp = lib.mkIf cfg.hardenMounts {
      useTmpfs = lib.mkDefault true;
      tmpfsSize = lib.mkDefault "50%";
    };
  };
}
