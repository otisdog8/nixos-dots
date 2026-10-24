# Kernel-log shipping over netconsole. Senders stream their printk feed
# (including the final oops/panic lines that never reach disk) as UDP datagrams
# to a collector k3s node, which ingests them into VictoriaLogs. All three k3s
# nodes are collectors (k3s module), so every node's panics are captured —
# each sender just targets a collector that isn't itself (arquitens, the
# default target, sends to carrack instead).
#
# Everything is a static boot param: source IP, egress device, collector
# IP/MAC are all known per host (`hosts` map below, read off `ip a`
# 2026-08-04 — pin DHCP reservations on the router). The one runtime bit left
# is *when* the module loads: most senders' LAN NIC is a USB dongle that
# hasn't enumerated when systemd-modules-load runs, and netconsole's init
# fails hard if the device isn't there — so a oneshot modprobes it after
# network-online instead of boot.kernelModules, and retries cover slow
# enumeration or a driver without netpoll support.
#
# Transport notes:
#  - netconsole is raw UDP from the kernel's netpoll layer — it rides the
#    physical NIC, NOT the tailnet (tun devices have no netpoll). Senders are
#    wired LAN hosts only.
#  - Sender identity: boot-param targets can't carry the configfs userdata
#    " host=" tag, so the collector names senders by source IP via hostMap
#    (another reason the DHCP reservations matter).
#  - The leading "+" makes netconsole a CON_EXTENDED console: records carry
#    priority/sequence metadata (parsed out by the collector's vector). It is
#    still loglevel-gated like any console — printk_get_next_message() applies
#    suppress_message_printing() to extended consoles too (only /dev/kmsg
#    readers bypass the loglevel), hence the kernel.printk raise below. Actual
#    oops/panic output is exempt either way: oops_enter()/panic() call
#    console_verbose() first.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.system.netconsole;

  # LAN facts per host, read off `ip a` 2026-08-04 (IPs earlier verified via
  # SSH-host-key matching). The egress device is addressed by its MAC-based
  # `enx...` altname (udev creates these by default; visible in `ip a`), so
  # the config survives USB-port moves and predictable-name changes — only a
  # NIC swap means updating the map. "enx" + 12 hex digits is 15 chars, which
  # fits netpoll's IFNAMSIZ (15 + NUL) limit exactly.
  hosts = {
    recusant = {
      ip = "10.0.0.2";
      mac = "98:b7:85:20:e3:e4"; # onboard enp4s0
    };
    galaxy = {
      ip = "10.0.0.3";
      mac = "00:24:27:88:a9:bd"; # USB dongle, enp17s0f3u1
    };
    arquitens = {
      ip = "10.0.0.10";
      mac = "00:24:27:88:a9:c4"; # USB dongle, enp4s0f4u1
    };
    carrack = {
      ip = "10.0.0.11";
      mac = "00:24:27:88:a9:bc"; # USB dongle, enp4s0f4u1
    };
    munificent = {
      ip = "10.0.0.12";
      mac = "00:24:27:88:a9:cd"; # USB dongle, enp4s0f4u1
    };
    # The hypervisors (docs/node-vms.md): the dongle again, on the locally
    # administered MAC its link rule sets. udev gives no enx altname for a
    # MAC that isn't the NIC's own, so the device is the name that rule keeps.
    arquitens-hv = {
      ip = "10.0.0.4";
      mac = "02:24:27:88:a9:c4";
      device = "enp4s0f4u1";
    };
    carrack-hv = {
      ip = "10.0.0.5";
      mac = "02:24:27:88:a9:bc";
      device = "enp4s0f4u1";
    };
    munificent-hv = {
      ip = "10.0.0.6";
      mac = "02:24:27:88:a9:cd";
      device = "enp4s0f4u1";
    };
  };
  altname = mac: "enx" + lib.replaceStrings [ ":" ] [ "" ] mac;
  self = hosts.${config.networking.hostName} or null;
in
{
  options.modules.system.netconsole = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Stream this host's kernel log to a collector over netconsole.
        Opt-in: the k3s module defaults it on for cluster nodes; recusant and
        galaxy enable it in their host configs. The roaming laptops stay off.
      '';
    };

    localIp = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = self.ip or null;
      defaultText = lib.literalExpression "hosts.\${hostname}.ip";
      description = "This host's LAN IP, stamped as the netconsole source address.";
    };

    device = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = if self != null then self.device or (altname self.mac) else null;
      defaultText = lib.literalExpression ''hosts.''${hostname}.device, else "enx<mac>" from its mac'';
      description = ''
        Egress NIC for netconsole datagrams (the wired LAN interface), as its
        MAC-based udev altname by default.
      '';
    };

    collectorIp = lib.mkOption {
      type = lib.types.str;
      default = hosts.arquitens.ip;
      description = ''
        LAN IP of the collector to send to. Must not be this host itself —
        arquitens overrides this to carrack.
      '';
    };

    collectorMac = lib.mkOption {
      type = lib.types.str;
      default = hosts.arquitens.mac;
      description = "MAC of the collector NIC (netconsole frames are pre-addressed).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 6666; # netconsole's conventional target port
      description = "UDP port the collectors listen on.";
    };

    collector = {
      enable = lib.mkEnableOption "the netconsole collector (UDP listener -> VictoriaLogs)";

      victoriaLogsUrl = lib.mkOption {
        type = lib.types.str;
        default = "http://10.43.169.2:9428";
        description = ''
          Base URL of the VictoriaLogs ingest endpoint. Default is the
          logs/victoria-logs-nodeport Service's ClusterIP (homelab pins it),
          which the collectors, all k3s nodes, reach from the host through
          Cilium's socket load balancing. Not a NodePort: that answered the
          whole query API, unauthenticated, on every node address.
        '';
      };

      hostMap = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = lib.mapAttrs' (name: h: lib.nameValuePair h.ip name) hosts;
        defaultText = lib.literalExpression "hosts map, inverted to ip -> name";
        description = "Source-IP -> hostname mapping (sender identity).";
      };
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !(cfg.enable && cfg.collectorIp == (self.ip or null));
          message = "modules.system.netconsole: ${config.networking.hostName} would netconsole to itself; set collectorIp/collectorMac to another collector node.";
        }
        {
          assertion = !cfg.enable || (cfg.localIp != null && cfg.device != null);
          message = "modules.system.netconsole: ${config.networking.hostName} is not in the module's hosts map; set localIp and device explicitly.";
        }
      ];
    }

    (lib.mkIf cfg.enable {
      # netconsole=[+][src-port]@[src-ip]/[dev],[tgt-port]@<tgt-ip>/[tgt-mac]
      # "+" = extended console. Module (not builtin) param, hence the
      # modprobe.d options line rather than a netconsole= kernel arg.
      boot.extraModprobeConfig = ''
        options netconsole netconsole=+@${toString cfg.localIp}/${toString cfg.device},${toString cfg.port}@${cfg.collectorIp}/${cfg.collectorMac}
      '';

      # The hardening profile pins kernel.printk to "3 3 3 3" (mkOverride 900),
      # which mutes everything below crit — on a healthy box that's a silent
      # netconsole feed. Senders raise the console level to 5 so the warning/
      # error tier (WARN() splats, I/O errors, hung tasks, shutdown progress)
      # ships too; message-default 4 keeps the unprefixed `echo | tee /dev/kmsg`
      # smoke test transmitting. Plain definition (prio 100) beats the
      # hardening's 900; non-sender laptops keep the full clamp. Applied live
      # by systemd-sysctl on switch — no reboot needed.
      boot.kernel.sysctl."kernel.printk" = "5 4 1 7";

      # Deliberately NOT boot.kernelModules: systemd-modules-load runs before
      # the USB LAN NICs enumerate, and netconsole's modprobe fails hard when
      # the device doesn't exist yet. Load after network-online instead, with
      # retries for slow enumeration; a driver without netpoll support keeps
      # failing visibly here (check `systemctl status netconsole-sender`).
      systemd.services.netconsole-sender = {
        description = "Load netconsole (kernel-log shipping to the collector)";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        unitConfig.StartLimitIntervalSec = 0;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.kmod}/bin/modprobe netconsole";
          Restart = "on-failure";
          RestartSec = "30s";
        };
      };
    })

    (lib.mkIf cfg.collector.enable {
      # tailscale0 is already trusted; this opens the LAN side, which is where
      # netconsole datagrams actually arrive. (Firewalls are currently mkForce'd
      # off on the k3s nodes — declared anyway for the eventual flip.)
      networking.firewall.allowedUDPPorts = [ cfg.port ];

      services.vector = {
        enable = true;
        # journal-shipping.nix turns it on in the same Vector instance.
        journaldAccess = lib.mkDefault false;
        settings = {
          sources.netconsole = {
            type = "socket";
            mode = "udp";
            address = "0.0.0.0:${toString cfg.port}";
          };

          transforms.netconsole_parse = {
            type = "remap";
            inputs = [ "netconsole" ];
            # Extended netconsole record: "<pri>,<seq>,<usec-since-boot>,<c|->;<text>"
            # (possibly plus " key=value" kernel dict continuation lines).
            # pri = facility<<3 | severity. Sender identity = source IP via
            # hostmap (boot-param netconsole targets can't tag userdata).
            source = ''
              hostmap = ${builtins.toJSON cfg.collector.hostMap}
              ip = replace(string(.host) ?? "unknown", r':\d+$', "")
              .source_ip = ip
              # get() yields null (not an error) on a missing key, so ?? alone
              # can't provide the fallback — null-check explicitly.
              mapped = get(hostmap, [ip]) ?? null
              .host = if mapped != null { mapped } else { ip }

              # Records over ~1000 bytes arrive split, with an extra
              # ",ncfrag=<byte-range>/<total>" header field per fragment.
              # Tolerated (header still parses, fragments tagged + ordered by
              # seq) but not reassembled — netconsd's ncrx is the only
              # receiver that does that, and it's not worth its C glue here.
              parsed, err = parse_regex(string(.message) ?? "", r'(?s)^(?P<pri>\d+),(?P<seq>\d+),(?P<boot_us>\d+),(?P<cont>[c-])(?P<extra>,[^;]*)?;(?P<rest>.*)$')
              if err == null {
                pri = to_int(parsed.pri) ?? 14
                .facility = to_int(floor(pri / 8))
                .level = to_syslog_level(mod(pri, 8)) ?? "info"
                .seq = to_int(parsed.seq) ?? 0
                # microseconds since sender boot (monotonic) — event time is the
                # receive timestamp vector already set; this orders panic lines.
                .boot_us = to_int(parsed.boot_us) ?? 0
                extra = string(parsed.extra) ?? ""
                if contains(extra, "ncfrag=") {
                  .ncfrag = replace(extra, ",ncfrag=", "")
                }
                .message = string(parsed.rest) ?? ""
              }
            '';
          };

          sinks.victorialogs = {
            type = "http";
            inputs = [ "netconsole_parse" ];
            uri = "${cfg.collector.victoriaLogsUrl}/insert/jsonline?_stream_fields=host&_msg_field=message&_time_field=timestamp";
            encoding.codec = "json";
            framing.method = "newline_delimited";
            # Kernel logs are low-volume and the interesting ones precede a
            # crash — ship promptly rather than batching for throughput.
            batch.timeout_secs = 1;
            # Crash bursts arrive exactly when infrastructure may be down
            # (collector rebooting, VictoriaLogs NodePort unreachable) — the
            # default in-memory buffer drops them on vector shutdown, which
            # already lost one arquitens reboot burst (2026-08-09). Spool to
            # disk instead (data_dir = the unit's StateDirectory,
            # /var/lib/vector) and block upstream rather than shed. 512 MiB;
            # vector rejects disk buffers smaller than 256 MiB + 32 B.
            buffer = {
              type = "disk";
              max_size = 536870912;
              when_full = "block";
            };
            # End-to-end acks: events leave the buffer only after VictoriaLogs
            # confirms the write, so a mid-flight restart replays instead of
            # dropping. `vector validate` WARNs that the UDP source can't
            # propagate acks upstream — inherent to netconsole's fire-and-forget
            # datagrams, not a config problem; the ack still gates buffer
            # deletion on the sink side.
            acknowledgements.enabled = true;
          };
        };
      };
    })
  ];
}
