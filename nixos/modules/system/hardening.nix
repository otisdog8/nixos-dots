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
    # In-kernel NTFS read/write drivers (ntfs3, and 7.x's new ntfs). Userspace
    # ntfs-3g (FUSE) still works if added to environment.systemPackages; this
    # only blocks the kernel drivers' auto-load on external-drive insert.
    "ntfs3"
    "ntfs"
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

  isGuest = cfg.profile == "vm-guest";
  isK3s = cfg.profile == "k3s-node";
  # This machine runs cluster node VMs (node-vm.nix): their NICs are macvtaps,
  # moved by vhost-net. (No such option in the VM guests' configurations.)
  runsNodeVms = (config.modules.system.nodeVms or { }) != { };

  # Kernel-surface blocks (blacklistSurface). Each group says why nothing here
  # needs it; the census (modprobe-census.nix) shows what the kernel still
  # asks for (hotplug and explicit loads don't go through it).
  surfaceModules =
    # PCI passthrough. No VM here gets a host device (crosvm's get virtio
    # ones, the GPU through virtio-nvgpu; nothing in the repo uses vfio).
    # Opening /dev/vfio/vfio would load them.
    [
      "vfio"
      "vfio_pci"
      "vfio_pci_core"
      "vfio_iommu_type1"
      "iommufd"
    ]
    # vhost backends no VM uses: crosvm serves its own disks, and there's no
    # vDPA hardware.
    ++ [
      "vhost_scsi"
      "vhost_vdpa"
    ]
    # vhost-net is the node VMs' (node-vm.nix vhostNet); the app and agent VMs'
    # network is passt. libvirt guests fall back to QEMU's own virtio-net.
    ++ lib.optional (!runsNodeVms) "vhost_net"
    # A guest runs no VMs of its own.
    ++ lib.optional isGuest "vhost_vsock"
    # Generic-netlink families a user namespace's root can autoload. No Open
    # vSwitch, GTP, B.A.T.M.A.N. or in-kernel OpenVPN here (OpenVPN falls back
    # to tun without ovpn). IPVS (ip_vs*, generated below, and xt_ipvs) is
    # kube-proxy's ipvs mode; k3s runs its default iptables mode (no
    # proxy-mode flag in k3s/default.nix or k3s-sensitive.nix).
    ++ [
      "openvswitch"
      "gtp"
      "batman_adv"
      "ovpn"
      "xt_ipvs"
    ]
    # IPsec's control plane (esp4/esp6: kernel.nix). No IKE daemon here,
    # Tailscale is WireGuard, and Cilium's encryption is off (WireGuard if it
    # is ever turned on: k3s/default.nix). xfrm_user stays on k3s nodes until
    # the census shows Cilium never touches XFRM state with encryption off.
    ++ lib.optional (!isK3s) "xfrm_user"
    ++ [
      "af_key"
      "xfrm_interface"
      "ip_vti"
      "ip6_vti"
      "ipcomp"
      "ipcomp6"
      "xfrm4_tunnel"
      "xfrm6_tunnel"
      "xfrm_ipcomp"
    ]
    # Other hypervisors' vsock transports (VMware, Hyper-V) and the loopback
    # one. The VMs here use vhost_vsock on the host, virtio in the guest.
    ++ [
      "vmw_vsock_vmci_transport"
      "vmw_vmci"
      "hv_sock"
      "vsock_loopback"
    ]
    # Netlink-reachable cores nothing here uses: the crypto API's config
    # netlink; RDMA (Ceph and NFS run over TCP); iSCSI (Rook's RBD/CephFS, no
    # initiator or Longhorn in the repo); MPLS.
    ++ [
      "crypto_user"
      "ib_core"
      "ib_cm"
      "iw_cm"
      "rdma_cm"
      "rdma_ucm"
      "ib_uverbs"
      "ib_umad"
      "ib_ipoib"
      "rdma_rxe"
      "siw"
      "rpcrdma"
      "scsi_transport_iscsi"
      "libiscsi"
      "libiscsi_tcp"
      "iscsi_tcp"
      "mpls_router"
      "mpls_iptunnel"
      "mpls_gso"
    ]
    # Conntrack helpers. The firewall loads none (autoLoadConntrackHelpers is
    # off), and neither kube-proxy's iptables mode nor Cilium uses them.
    ++ [
      "nf_conntrack_ftp"
      "nf_conntrack_sip"
      "nf_conntrack_h323"
      "nf_conntrack_irc"
      "nf_conntrack_pptp"
      "nf_conntrack_tftp"
      "nf_conntrack_amanda"
      "nf_conntrack_sane"
      "nf_conntrack_netbios_ns"
      "nf_conntrack_snmp"
      "nf_conntrack_broadcast"
      "nf_nat_ftp"
      "nf_nat_sip"
      "nf_nat_h323"
      "nf_nat_irc"
      "nf_nat_pptp"
      "nf_nat_tftp"
      "nf_nat_amanda"
      "nf_nat_snmp_basic"
    ]
    # Virtual netdevs a user namespace's root can create (rtnl-link-*), unused
    # here (vcan/vxcan: netModules).
    ++ [
      "bareudp"
      "team"
      "team_mode_activebackup"
      "team_mode_broadcast"
      "team_mode_loadbalance"
      "team_mode_random"
      "team_mode_roundrobin"
      "netdevsim"
      "nlmon"
      "ifb"
      "vrf"
    ]
    # Cilium's tunnel (VXLAN; geneve if it's ever switched) and lcm-gateway's
    # ipvlan are the k3s nodes'. macvlan stays there too: k3s ships the
    # macvlan CNI plugin and the workloads live in the homelab repo, so only
    # the census can clear it.
    ++ lib.optionals (!isK3s) [
      "vxlan"
      "geneve"
      "ipvlan"
    ]
    # The node VMs' NICs are macvtaps (node-vm.nix).
    ++ lib.optionals (!isK3s && !runsNodeVms) [
      "macvlan"
      "macvtap"
    ];

  # Autoload aliases pointed at an install-false name, instead of an install
  # rule on the module itself: macsec and tls are also symbol dependencies of
  # NIC drivers (atlantic and the mscc PHYs need macsec; bonding, cxgb4, nfp
  # and funeth need tls), and an install rule on them would stop those
  # drivers loading. With these, the drivers still load; what a user
  # namespace could trigger (a macsec link, its genl family, kTLS's
  # TCP_ULP "tls") doesn't. nginx and the NFS mounts don't enable kTLS.
  aliasBlocks = {
    macsec = [
      "rtnl-link-macsec"
      "net-pf-16-proto-16-family-macsec"
    ];
    tls = lib.optionals (!role.ktls) [ "tcp-ulp-tls" ];
  };

  # Servers, k3s and guests: radio cores (every Wi-Fi, Bluetooth, 802.15.4
  # and 6LoWPAN driver depends on one; nfc: netModules). No server has a
  # radio in use; recusant has no Bluetooth (its default.nix).
  radioModules = [
    "bluetooth"
    "cfg80211"
    "mac80211"
    "ieee802154"
    "mac802154"
    "6lowpan"
  ];
  # Servers and k3s: the media (V4L2, media controller, DVB) and sound cores.
  # Jellyfin's transcoding on recusant is VA-API on the iGPU's render node
  # (DRM), not V4L2; no GPU driver depends on these (cec, which i915 and
  # amdgpu do, stays). Not the guests: cameras attach to app VMs as USB
  # devices (uvcvideo).
  mediaModules = [
    "videodev"
    "mc"
    "dvb_core"
    "soundcore"
    "snd"
  ];

  # Modules something here loads by name are never blocked by the surface,
  # radio and media lists (node-vm.nix's macvtap/vhost_net, the guests'
  # virtio set, ...). Not the older lists: af_alg is in the initrd's
  # availableKernelModules (LUKS), and blocked on purpose. tls is the
  # exception (hardening-modules.nix blacklistOnly).
  norm = lib.replaceStrings [ "-" ] [ "_" ];
  loadedByName = lib.remove "tls" (
    map norm (config.boot.kernelModules ++ config.boot.initrd.kernelModules)
  );
  unlessLoaded = lib.filter (m: !lib.elem (norm m) loadedByName);

  blocked =
    lib.optionals cfg.blacklistFs fsModules
    ++ lib.optionals cfg.blacklistNet netModules
    ++ lib.optionals cfg.blacklistTty ttyModules
    ++ lib.optionals cfg.blacklistAfAlg afAlgModules
    ++ lib.optionals cfg.blacklistMisc miscModules
    ++ unlessLoaded (
      lib.optionals cfg.blacklistSurface surfaceModules
      ++ lib.optionals cfg.blacklistRadio radioModules
      ++ lib.optionals cfg.blacklistMedia mediaModules
    );

  false' = "${pkgs.coreutils}/bin/false";
  mkInstallFalse = mods: lib.concatMapStringsSep "\n" (m: "install ${m} ${false'}") mods;

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

  role = {
    inherit isGuest isK3s;
    isWorkstation = cfg.profile == "workstation";
    laptop = config.modules.system.laptop.enable or false;
    sensitive = config.modules.system.k3sSensitive.enable or false;
    nfsServer = config.services.nfs.server.enable;
    nfsClient =
      isK3s || lib.any (fs: lib.hasPrefix "nfs" fs.fsType) (lib.attrValues config.fileSystems);
    ktls = lib.any (v: v.kTLS or false) (lib.attrValues config.services.nginx.virtualHosts);
  };
  generated = import ./hardening-modules.nix { inherit lib role; };

  # hardening-modules.nix's blocks, against this kernel's tree (its
  # modules.order) and the system's modules.dep (out-of-tree modules
  # included), at build time: hardening-blocks.py.
  generatedBlocks =
    pkgs.runCommand "modprobe-hardening-generated.conf"
      {
        request = builtins.toJSON {
          inherit (generated)
            names
            prefixes
            exclude
            keepPatterns
            blacklistOnly
            ;
          keep =
            generated.keep
            ++ cfg.keepModules
            ++ loadedByName
            ++ map norm config.boot.initrd.availableKernelModules;
        };
        passAsFile = [ "request" ];
        order = lib.getOutput "modules" config.boot.kernelPackages.kernel;
        tree = config.system.modulesTree;
      }
      ''
        ${pkgs.python3}/bin/python3 -I ${./hardening-blocks.py} "$requestPath" "$order" "$tree" ${false'} "$out"
      '';

  # Sit between NixOS's mkDefault (1000) and a normal value (100): wins over
  # upstream defaults but per-host overrides via bare value or lib.mkForce
  # still take precedence.
  # Ones the kernel lacks (skipSysctls) are left out.
  hardenSysctls = attrs: lib.mapAttrs (_: lib.mkOverride 900) (removeAttrs attrs cfg.skipSysctls);
in
{
  imports = [ ./modprobe-census.nix ];

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

    blacklistSurface = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Block kernel surface nothing here uses but a user namespace or an
        unprivileged user can autoload: PCI passthrough, unused vhost
        backends, generic-netlink families, IPsec's control plane, foreign
        vsock transports, RDMA/iSCSI/MPLS, conntrack helpers, unused virtual
        netdevs and most of traffic control (per role; see surfaceModules),
        plus the generated blocks of hardening-modules.nix.
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

    keepModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "snd_oxygen" ];
      description = ''
        Modules (and their dependencies) the generated blocks
        (hardening-modules.nix) must leave alone on this host, e.g. a sound
        card's legacy PCI driver.
      '';
    };

    blacklistRadio = lib.mkOption {
      type = lib.types.bool;
      default = cfg.profile != "workstation";
      description = "Block the Wi-Fi, Bluetooth, 802.15.4 and 6LoWPAN cores (servers, k3s, VM guests).";
    };

    blacklistMedia = lib.mkOption {
      type = lib.types.bool;
      default = cfg.profile == "server" || isK3s;
      description = "Block the V4L2/media-controller, DVB and sound cores (servers and k3s).";
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

    boot.blacklistedKernelModules = blocked;

    # Defense in depth alongside blacklistedKernelModules: the kernel's own
    # requests (request_module) don't honour blacklist, install rules they do.
    # Same pattern as kernel.nix's esp4/esp6/rxrpc.
    boot.extraModprobeConfig = ''
      ${mkInstallFalse blocked}
    ''
    + lib.optionalString cfg.blacklistSurface (
      lib.concatStrings (
        lib.mapAttrsToList (name: aliases: ''
          ${lib.concatMapStrings (a: "alias ${a} blocked-${name}\n") aliases}install blocked-${name} ${false'}
        '') (lib.filterAttrs (_: aliases: aliases != [ ]) aliasBlocks)
      )
    );
    environment.etc."modprobe.d/hardening-generated.conf" = lib.mkIf cfg.blacklistSurface {
      source = generatedBlocks;
    };

    # No bcache: NixOS's udev rule registers any block device (a loop image
    # too) that carries a bcache superblock, unasked, and nothing uses it.
    # bcachefs (recusant) is a separate module and stays. The module is
    # blocked in hardening-modules.nix.
    boot.bcache.enable = lib.mkDefault false;

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
    # TODO: consider raising lockdown to integrity at runtime after boot (a
    # timer ~15 min after boot, so a bad setting can't brick early boot; a
    # one-way write to /sys/kernel/security/lockdown). Under integrity only
    # signed modules load, and the modules here load unsigned
    # (TAINT_UNSIGNED_MODULE on excelsior, in-tree ones included): so every
    # module a host will ever need must have loaded by then (nvidia,
    # v4l2loopback, the nvgpu kmod, drbd, and the hotplugged ones), or
    # nixpkgs' module signing must be sorted out first.
    # Desktops could likely take confidentiality (it breaks kernel-memory
    # reads: kprobes, bpftrace, perf kernel samples, /proc/kcore; Cilium and
    # Tetragon only matter on k3s). Not obviously necessary.

    # TODO (low priority): sudo-rs or run0 instead of setuid sudo, and
    # security.sudo.execWheelOnly meanwhile. sudo-rs is memory-safe with
    # fewer features, but has had logic CVEs of its own.

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
