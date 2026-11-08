# The generated module blocks (hardening.nix blocksConf, written by
# hardening-blocks.py from the kernel's own tree at build time): exact names,
# fnmatch patterns and path prefixes in the kernel's modules.order. Whatever
# the system loads by name, every out-of-tree module, the keep names below
# and everything any of them depends on are never blocked. A name this kernel
# doesn't have is a no-op, listed in the file's last comment line.
#
# Each group says why nothing here needs it; the census
# (modprobe-census.nix, `journalctl -t kmod-request`) shows what the kernel
# still asks for (hotplug and explicit loads don't go through it).
{ lib, role }:
let
  inherit (lib) optionals;
  notK3s = !role.isK3s;
in
{
  # Kept with their dependencies even where nothing loads them by name yet:
  # hotplugged drivers a block's dependency could otherwise take out.
  keep = [
    # Traffic control's keep list (prefixes below).
    "sch_fq_codel"
    "sch_fq"
  ]
  ++ optionals role.isK3s [
    "sch_ingress"
    "cls_bpf"
    "act_bpf"
  ]
  ++ [
    "snd_usb_audio"
    "snd_hda_intel"
    "uvcvideo"
    "btusb"
    "r8152"
    "r8169"
    "asix"
    "ax88179_178a"
    "cdc_ether"
    "cdc_ncm"
    "cdc_acm"
    "atlantic"
    "igc"
    "e1000e"
    "xhci_pci"
    "usbhid"
    "hid_generic"
    "hid_multitouch"
    "usb_storage"
    "uas"
    "virtio_gpu"
    "i915"
    "xe"
    "amdgpu"
  ];
  keepPatterns = [
    # Intel laptops' audio (SOF, SoundWire, ASoC).
    "snd_sof*"
    "snd_soc_*"
  ];

  exclude =
    # The WWAN modems' serial side (option, qcserial, sierra) under usb/serial.
    [
      "option"
      "usb_wwan"
      "qcserial"
      "qcaux"
      "sierra"
    ]
    # DRBD 9 (out of tree) on the sensitive servers has the in-tree name.
    ++ optionals role.sensitive [ "drbd" ];

  prefixes = [
    # Traffic control: qdiscs, classifiers, actions and ematches, all
    # loadable by a user namespace's root through rtnetlink (the net/sched LPE
    # class). Kept (keep): fq_codel is systemd's default qdisc, fq paces
    # BBR and Cilium's bandwidth manager; Cilium attaches with clsact
    # (sch_ingress) and cls_bpf where tcx isn't used. mq is built in.
    "kernel/net/sched/"
    # IPVS: kube-proxy's ipvs mode; k3s runs its default iptables mode (no
    # proxy-mode flag in k3s/default.nix or k3s-sensitive.nix).
    "kernel/net/netfilter/ipvs/"
    # Every USB-serial bridge (cp210x, ch341, ftdi_sio and pl2303 included),
    # but the WWAN modems' (exclude): the 2016 malicious-descriptor class,
    # and no microcontroller work here.
    "kernel/drivers/usb/serial/"
    # Legacy PCI and PCMCIA sound cards (also Xonar/oxygen, X-Fi/ctxfi,
    # RME, emu10k1 and snd-ac97-codec; never ac97_bus, which ASoC needs).
    # HDA is sound/hda. A host with such a card keeps it (keepModules).
    "kernel/sound/pci/"
    "kernel/sound/pcmcia/"
  ];

  names =
    # --- A: autoloadable by any uid ---
    # GOST signature/hash: an unprivileged add_key of such a cert loads them.
    [
      "ecrdsa_generic"
      "streebog_generic"
    ]
    # Ciphers that XFRM/PF_KEY algorithm probing and kTLS load (both blocked
    # or unused here), and AF_ALG/root-only ones. Kept: libarc4 (mac80211),
    # cts, essiv, cryptd, crypto_null, camellia (krb5 and Ceph select it).
    ++ [
      "cast5*"
      "cast6*"
      "cast_common"
      "blowfish*"
      "twofish*"
      "serpent*"
      "des_generic"
      "sm3*"
      "sm4*"
      "rmd160"
      "xcbc"
      "aria*"
      "deflate"
      "anubis"
      "khazad"
      "tea"
      "seed"
      "md4"
      "wp512"
      "aegis128*"
      "lrw"
      "xctr"
      "hctr2"
      "adiantum"
      "pcrypt"
      "krb5enc"
      "arc4"
      "842"
      "lz4hc"
      "authencesn"
    ]
    # IPsec's leftovers (xfrm_user and the rest: hardening.nix surfaceModules).
    ++ [
      "xfrm_compat"
      "xfrm_iptfs"
      "ah4"
      "ah6"
      "mip6"
      "esp4_offload"
      "esp6_offload"
    ]
    # Genetlink lookups autoload these with no capability check. nbd is the
    # Ceph CSI's on k3s (k3s/default.nix loads it); WireGuard is Cilium's
    # (if its encryption is ever on). Tailscale is wireguard-go in userspace.
    ++ optionals notK3s [
      "nbd"
      "wireguard"
    ]
    ++ [
      "nsh"
      "hsr"
      "ife"
      "psample"
    ]
    # NPUs (/dev/accel*, 0666 for render): nothing here uses one.
    ++ [
      "amdxdna"
      "intel_vpu"
      "habanalabs"
      "qaic"
    ]
    # vDPA and VDUSE (userspace impersonating virtio devices), UIO, the LIO
    # target, NVMe over fabrics and its target: unused, and network-facing
    # parsers once configured.
    ++ [
      "vdpa"
      "vduse"
      "virtio_vdpa"
      "ifcvf"
      "mlx5_vdpa"
      "vp_vdpa"
      "alibaba_eni_vdpa"
      "snet_vdpa"
      "pds_vdpa"
      "octep_vdpa"
      "vdpa_sim*"
      "uio"
      "uio_*"
      "target_core_mod"
      "nvme_fabrics"
      "nvme_tcp"
      "nvme_rdma"
      "nvme_fc"
      "nvmet*"
      "nvme_loop"
      "nvme_fcloop"
    ]
    # iSCSI and FCoE HBAs and their glue (the initiator: surfaceModules).
    ++ [
      "iscsi_boot_sysfs"
      "iscsi_ibft"
      "cxgb3i"
      "cxgb4i"
      "bnx2i"
      "be2iscsi"
      "qla4xxx"
      "qedi"
      "libfc"
      "libfcoe"
      "fcoe"
      "fnic"
      "bnx2fc"
      "qedf"
      "csiostor"
    ]
    ++ [
      "vsock_diag"
      "vsockmon"
    ]

    # bcache (hardening.nix turns its auto-register rule off too).
    ++ [ "bcache" ]

    # --- B: reachable from a user namespace ---
    # xt/nft extensions nothing here uses: nft_compat turns any xt name into an
    # autoload from a userns (xt_u32 CVE-2023-39192, xt_sctp CVE-2023-39193).
    # The firewalls here use conntrack, multiport, owner, mark/connmark,
    # pkttype, rpfilter, REJECT and MASQUERADE.
    ++ [
      "xt_AUDIT"
      "xt_CONNSECMARK"
      "xt_SECMARK"
      "xt_HMARK"
      "xt_IDLETIMER"
      "xt_LED"
      "xt_NETMAP"
      "xt_RATEEST"
      "xt_rateest"
      "xt_TCPOPTSTRIP"
      "ipt_ECN"
      "xt_ecn"
      "xt_cluster"
      "xt_cpu"
      "xt_dccp"
      "xt_devgroup"
      "xt_realm"
      "xt_sctp"
      "xt_u32"
      "xt_string"
      "xt_time"
      "xt_quota"
      "nft_quota"
      "arpt_mangle"
      "ip6t_eui64"
      "ip6t_frag"
      "ip6t_hbh"
      "ip6t_ipv6header"
      "ip6t_mh"
      "ip6t_rt"
      "ip6t_srh"
      "ip6t_NPT"
    ]
    # ...and these too, off the k3s nodes, whose kube-proxy, Cilium and pods
    # (the homelab repo, not readable here) may use them: lsmod there first.
    ++ optionals notK3s [
      "xt_CHECKSUM"
      "xt_CLASSIFY"
      "xt_DSCP"
      "xt_dscp"
      "xt_hl"
      "xt_HL"
      "xt_TCPMSS"
      "xt_tcpmss"
      "xt_bpf"
      "xt_cgroup"
      "xt_connbytes"
      "xt_connlabel"
      "xt_connlimit"
      "nft_connlimit"
      "nf_conncount"
      "xt_hashlimit"
      "xt_iprange"
      "xt_length"
      "xt_mac"
      "xt_physdev"
      "nft_numgen"
      "nft_hash"
      "nft_redir"
      "xt_REDIRECT"
    ]
    # NFQUEUE/NFLOG and friends: nothing consumes them (the firewall logs
    # with LOG). nfacct is kube-proxy's metrics.
    ++ [
      "nfnetlink_queue"
      "nfnetlink_log"
      "nfnetlink_osf"
      "nfnetlink_hook"
      "nfnetlink_cthelper"
      "nfnetlink_cttimeout"
      "xt_NFQUEUE"
      "xt_NFLOG"
      "nft_queue"
      "nft_osf"
      "xt_osf"
      "ebt_nflog"
      "xt_helper"
    ]
    ++ optionals notK3s [
      "nfnetlink_acct"
      "xt_nfacct"
    ]
    # Packet duplication, netdev-family forwarding, flowtables, SYNPROXY,
    # bridge filtering (no bridges are filtered here), the IPsec/tunnel matches.
    ++ [
      "nf_dup_netdev"
      "nft_dup_netdev"
      "nft_fwd_netdev"
      "nft_fib_netdev"
      "nft_reject_netdev"
      "nf_dup_ipv4"
      "nf_dup_ipv6"
      "nft_dup_ipv4"
      "nft_dup_ipv6"
      "xt_TEE"
      "nf_flow_table"
      "nf_flow_table_inet"
      "nft_flow_offload"
      "nf_synproxy_core"
      "nft_synproxy"
      "ipt_SYNPROXY"
      "ip6t_SYNPROXY"
      "ebt_*"
      "nft_meta_bridge"
      "nft_reject_bridge"
      "nf_conntrack_bridge"
      "nft_xfrm"
      "nft_tunnel"
      "xt_policy"
      "xt_esp"
      "ipt_ah"
      "ip6t_ah"
      "xt_ipcomp"
      "xt_l2tp"
    ]
    # The k3s datapath (kube-proxy, Cilium's proxy, ipset), off the clusters.
    # On every k3s role all of it stays: without xt_recent, kube-proxy's
    # whole iptables-restore batch fails.
    ++ optionals notK3s [
      "xt_TPROXY"
      "nf_tproxy_ipv4"
      "nf_tproxy_ipv6"
      "nft_tproxy"
      "xt_socket"
      "nft_socket"
      "nf_socket_ipv4"
      "nf_socket_ipv6"
      "xt_CT"
      "xt_statistic"
      "xt_recent"
      "ip_set"
      "ip_set_*"
      "xt_set"
      "nf_conntrack_netlink"
      "br_netfilter"
    ]
    # Tunnels: loading one registers host-wide GRE/IPIP decapsulation. Kept on
    # k3s, where Cilium may use IPIP (DSR). udp_tunnel stays everywhere.
    ++ optionals notK3s [
      "ipip"
      "ip_gre"
      "gre"
      "ip6_gre"
      "sit"
      "ip6_tunnel"
      "tunnel4"
      "tunnel6"
      "ip_tunnel"
      "fou"
      "fou6"
      "ila"
    ]
    # More rtnl-link kinds a userns can create. No bonds or VLANs anywhere in
    # the repo (8021q stays on k3s for pods).
    ++ [
      "pfcp"
      "amt"
      "ipvtap"
      "virt_wifi"
      "rmnet"
      "dsa_core"
      "bonding"
    ]
    ++ optionals notK3s [ "8021q" ]

    # --- C: filesystems and block ---
    # Crafted-image parsers nothing mounts (AppImages use squashfuse), network
    # filesystems nothing uses (guests use virtiofs), and no quotas.
    ++ [
      "squashfs"
      "erofs"
      "f2fs"
      "ext2"
      "romfs"
      "ubifs"
      "zonefs"
      "msdos"
      "cifs"
      "cifs_md4"
      "smb_compress"
      "ksmbd"
      "kafs"
      "9p"
      "orangefs"
      "vboxsf"
      "dlm"
      "ocfs2*"
      "cachefiles"
      "ecryptfs"
      "cuse"
      "ramoops"
      "pstore_blk"
      "pstore_zone"
      "quota_v1"
      "quota_v2"
      "quota_tree"
    ]
    # CephFS is the k3s pods' (Rook).
    ++ optionals notK3s [ "ceph" ]
    # NFS: the k3s nodes mount recusant's export, vers=4.2 only (k3s/nfs.nix);
    # recusant serves it. No v2, pNFS layouts, Kerberos or RDMA.
    ++ [
      "nfsv2"
      "nfs_layout_nfsv41_files"
      "nfs_layout_flexfiles"
      "blocklayoutdriver"
      "rpcsec_gss_krb5"
    ]
    ++ optionals (!role.nfsServer) [ "nfsd" ]
    ++ optionals (!role.nfsClient) [
      "nfs"
      "nfsv3"
      "nfsv4"
    ]
    # Nobody plugs media into the servers, nodes or VMs.
    ++ optionals (!role.isWorkstation) [
      "exfat"
      "isofs"
    ]
    # Exotic and test device-mapper targets. Kept: crypt, thin, snapshot,
    # mirror, raid, integrity, verity, cache, writecache, md and raid*.
    ++ [
      "dm_era"
      "dm_clone"
      "dm_vdo"
      "dm_pcache"
      "dm_switch"
      "dm_multipath"
      "dm_round_robin"
      "dm_queue_length"
      "dm_service_time"
      "dm_historical_service_time"
      "dm_io_affinity"
      "dm_zoned"
      "dm_ebs"
      "dm_unstripe"
      "dm_log_userspace"
      "dm_dust"
      "dm_flakey"
      "dm_delay"
      "dm_log_writes"
      "md_cluster"
    ]

    # --- D: physical hotplug ---
    # A Thunderbolt/USB4 peer autoloads these via XDomain, unauthorized.
    ++ [
      "thunderbolt_net"
      "thunderbolt_dma_test"
      "thunderbolt_stream"
    ]
    # PCI-ID-matched drivers a malicious Thunderbolt PCIe device can trigger
    # (altera_cvp matches any Altera device).
    ++ [
      "altera_cvp"
      "dfl_pci"
      "fpga_mgr"
      "fpga_bridge"
      "fpga_region"
      "dfl"
      "ntb"
      "ipack"
      "tpci200"
      "ipoctal"
      "mcb"
      "mcb_pci"
      "mcb_lpc"
      "intel_th"
      "intel_th_*"
      "stm_core"
      "counter"
      "intel_qep"
      "interrupt_cnt"
      "dwc_pcie_pmu"
      "cxl_pmu"
      "firewire_nosy"
    ]
    # It loads beside `button`, and if it wins the bind, the power key goes
    # straight to PID 1, past HandlePowerKey=ignore and the k3s drain (the
    # carrack outage's failure).
    ++ [ "tiny_power_button" ]
    # USB misc and test drivers, usbip, usbmon; usbkbd/usbmouse duplicate
    # usbhid.
    ++ [
      "emi62"
      "emi26"
      "adutux"
      "usbsevseg"
      "legousbtower"
      "usblcd"
      "cypress_cy7c63"
      "cytherm"
      "idmouse"
      "appledisplay"
      "apple_mfi_fastcharge"
      "sisusbvga"
      "ldusb"
      "trancevibrator"
      "iowarrior"
      "usbtest"
      "ehset"
      "lvstest"
      "isight_firmware"
      "yurex"
      "ezusb"
      "usb251xb"
      "usb3503"
      "usb4604"
      "chaoskey"
      "usbtmc"
      "mdc800"
      "microtek"
      "usbkbd"
      "usbmouse"
      "usbmon"
      "usbip_core"
      "vhci_hcd"
      "usbip_host"
    ]
    # Legacy USB input with heavy USB-fuzzing history (appletouch and bcm5974,
    # MacBook trackpads, stay), and Xillybus.
    ++ [
      "usbtouchscreen"
      "sur40"
      "acecad"
      "aiptek"
      "hanwang"
      "kbtab"
      "pegasus_notetaker"
      "synaptics_usb"
      "iforce"
      "pxrc"
      "ati_remote2"
      "keyspan_remote"
      "powermate"
      "yealink"
      "cm109"
      "ims_pcu"
      "xillyusb"
      "xillybus_pcie"
      "xillybus_of"
      "xillybus_core"
      "xillybus_class"
    ]
    # USB bridge chips (I2C/SPI/GPIO over USB). nct6694 is a USB-attached
    # Nuvoton chip, not the boards' Super I/O (nct6775) that reads the fans.
    # usb_ljca/usbio carry the IPU6 cameras on Intel laptops.
    ++ [
      "dln2"
      "i2c_diolan_u2c"
      "i2c_tiny_usb"
      "i2c_robotfuzz_osif"
      "i2c_cp2615"
      "viperboard"
      "spi_ch341"
      "gpio_mpsse"
      "nct6694"
      "pcwd_usb"
    ]
    ++ optionals (!role.laptop) [
      "usb_ljca"
      "usbio"
    ]
    # 1-Wire: with a DS2490 plugged in, its netlink connector is open to any uid.
    ++ [
      "wire"
      "ds2490"
      "ds2482"
      "w1_gpio"
      "matrox_w1"
      "sgi_w1"
      "w1_uart"
      "amd_axi_w1"
    ]
    # IR receivers (the decoders and rc-* keymaps stay: CEC and DVB use them).
    ++ [
      "ene_ir"
      "fintek_cir"
      "gpio_ir_recv"
      "gpio_ir_tx"
      "ir_hix5hd2"
      "igorplugusb"
      "iguanair"
      "imon"
      "imon_raw"
      "ite_cir"
      "mceusb"
      "nuvoton_cir"
      "pwm_ir_tx"
      "redrat3"
      "serial_ir"
      "ir_spi"
      "streamzap"
      "ir_toy"
      "ttusbir"
      "winbond_cir"
      "ati_remote"
      "rc_loopback"
      "xbox_remote"
    ]
    # BadUSB targets that pull in staging-quality code.
    ++ [
      "comedi"
      "gpib_common"
      "greybus"
      "gb_es2"
    ]
    # Legacy fbdev drivers and virtual/foreign-hypervisor DRM. The displays
    # here are amdgpu, i915/xe, nvidia and virtio-gpu (the VMs).
    ++ [
      "nvidiafb"
      "rivafb"
      "radeonfb"
      "aty128fb"
      "atyfb"
      "savagefb"
      "sisfb"
      "viafb"
      "neofb"
      "kyrofb"
      "tdfxfb"
      "sstfb"
      "tridentfb"
      "pm2fb"
      "pm3fb"
      "i740fb"
      "cirrusfb"
      "cyber2000fb"
      "carminefb"
      "sm501fb"
      "sm712fb"
      "gxt4500"
      "arcfb"
      "vga16fb"
      "uvesafb"
      "hecubafb"
      "n411"
      "ocfb"
      "s1d13xxxfb"
      "metronomefb"
      "mb862xxfb"
      "ssd1307fb"
      "vfb"
      "vgem"
      "vkms"
      "vmwgfx"
      "vboxvideo"
      "qxl"
      "bochs"
      "cirrus_qemu"
      "hyperv_drm"
      "drm_xen_front"
      "xen_fbfront"
    ]
    # Desktops: mac_hid loads for every keyboard, nothing reads
    # /dev/input/mice, and no PC speaker.
    ++ optionals role.isWorkstation [
      "mac_hid"
      "pcspkr"
      "mousedev"
    ]
    # Autoload gaps the hotplug analysis found: a pty ldisc (NCI) and two
    # rtnl-link kinds a userns can create (lowpan, virt_wifi above).
    ++ [
      "nci_uart"
      "ieee802154_6lowpan"
    ]

    # --- E: sound through the seat/group ---
    # The ALSA sequencer, historically ALSA's buggiest part, which PipeWire
    # opens silently: desktops lose MIDI routing and Wine's General MIDI only.
    # snd_seq_device, snd_rawmidi and snd_ump stay (snd_usb_audio).
    ++ optionals role.isWorkstation [
      "snd_seq"
      "snd_seq_dummy"
      "snd_seq_midi"
      "snd_seq_midi_event"
      "snd_seq_midi_emul"
      "snd_seq_virmidi"
      "snd_virmidi"
      "snd_hrtimer"
    ]
    # OSS emulation, the PC-speaker driver and the test drivers.
    ++ [
      "snd_pcm_oss"
      "snd_mixer_oss"
      "snd_seq_oss"
      "snd_pcsp"
      "snd_dummy"
      "snd_aloop"
      "snd_pcmtest"
    ]

    # --- F: root-only test/debug modules (cheap defence in depth) ---
    # pci_endpoint_test autoloads by PCI ID; the simulators become reachable
    # once loaded. udc_core takes the whole USB gadget stack (dwc3 on Intel
    # laptops is then unbound, which is harmless).
    ++ [
      "mock_file"
      "dmapool_test"
      "hwpoison_inject"
      "test_lockup"
      "scftorture"
      "torture"
      "refscale"
      "preemptirq_delay_test"
      "kprobe_event_gen_test"
      "remote_test"
      "punit_atom_debug"
      "pci_endpoint_test"
      "dmatest"
      "rtc_test"
      "test_power"
      "thermal_testing"
      "x509_selftest"
      "pkcs7_test_key"
      "pkcs8_key_parser"
      "tcrypt"
      "mailbox_test"
      "spi_loopback_test"
      "i2c_stub"
      "i2c_slave_eeprom"
      "i2c_slave_testunit"
      "gpio_mockup"
      "gpio_sim"
      "gpio_virtuser"
      "gpio_aggregator"
      "gpio_sloppy_logic_analyzer"
      "ptp_mock"
      "pps_gen_dummy"
      "pps_gen_tio"
      "pps_ktimer"
      "pps_gpio"
      "scsi_debug"
      "null_blk"
      "rnull_mod"
      "brd"
      "zloop"
      "aoe"
      "rnbd_client"
      "rnbd_server"
      "mtip32xx"
      "xen_blkfront"
      "xen_blkback"
      "drbd"
      "mac80211_hwsim"
      "wwan_hwsim"
      "fakelb"
      "mac802154_hwsim"
      "dsa_loop"
      "rocker"
      "udc_core"
      "mce_inject"
      "einj"
      "erst_dbg"
      "ec_sys"
      "acpi_configfs"
      "pfr_update"
      "pfr_telemetry"
      "amd_pstate_ut"
      "cpuid"
      "nd_e820"
      "phram"
      "slram"
      "mtdram"
      "block2mtd"
      "nandsim"
      "speakup"
      "bfq"
      "aer_inject"
      "acpiphp_ibm"
      "switchtec"
      "edd"
      "qemu_fw_cfg"
      "kvmgt"
      "tpm_vtpm_proxy"
      "tpm_nsc"
      "tpm_atmel"
      "tpm_infineon"
      "xen_tpmfront"
      "tpm_svsm"
      "tpm_st33zp24*"
      "hangcheck_timer"
      "tlclk"
      "ttyprintk"
      "ttynull"
      "lp"
      "ppdev"
      "parport"
      "parport_pc"
      "pcmcia"
      "yenta_socket"
      "rio_*"
      "rapidio"
      "soundwire_qcom"
      "fsi_core"
      "peci"
      "most_core"
      "rpmsg_core"
      "virtio_iommu"
      "libnvdimm"
      "device_dax"
      "dax_hmem"
      "kmem"
      "amdtee"
      "hsmp_acpi"
      "amd_hsmp"
      "intel_ifs"
    ]
    # SPI/I2C TPMs: some laptops' TPM sits there (LUKS unlock), and
    # thinkpad_acpi needs nvram: not on laptops.
    ++ optionals (!role.laptop) [
      "nvram"
      "tpm_tis_spi"
      "tpm_tis_i2c*"
      "tpm_i2c_*"
    ];

  # Skipped by systemd-modules-load, still loadable as a dependency (bonding,
  # cxgb4, nfp need it). nixpkgs' nginx module puts tls in boot.kernelModules
  # whatever the vhosts say; no vhost here sets kTLS.
  blacklistOnly = optionals (!role.ktls) [ "tls" ];
}
