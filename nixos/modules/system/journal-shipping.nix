# Host journals into VictoriaLogs. Pod logs already arrive through the
# cluster's Vector DaemonSet and kernel panics through netconsole; this ships
# each host's own journal (k3s, tailscaled, sshd, nix-daemon, recusant's
# Minecraft and Garage units, ...), so it can be searched and alerted on next
# to the cluster's logs, kept for VictoriaLogs' retention, and read when the
# host itself is down. The journal also stays on the host (/var/log is
# persisted under /large).
#
# Transport: Vector's journald source to VictoriaLogs' jsonline API.
#  - k3s nodes post from the host to the logs/victoria-logs-nodeport ClusterIP,
#    as the netconsole collector does, so a broken ingress doesn't take their
#    logs with it.
#  - every other host posts to https://logs-ingest.k8s.rooty.dev over the
#    tailnet (svc:k8s, then Traefik: /insert/ only, and only from the tailnet
#    path; homelab apps/infra/logs). The gateways' Vector posts there too,
#    with the same stream fields, so one query covers hosts and gateways.
#
# Vector's state (/var/lib/vector, under DynamicUser /var/lib/private/vector)
# is persisted wherever Vector runs: its journal checkpoint, so a reboot
# resumes where it stopped instead of skipping the old boot's tail, and its
# disk buffers, so lines spooled while the endpoint was away survive a reboot
# (on the k3s nodes that includes the netconsole collector's crash bursts).
# The journald source resumes from the checkpoint across boots; with none
# (the first start) it begins at "now" rather than backfilling the host's
# whole persisted journal.
{
  config,
  lib,
  ...
}:
let
  cfg = config.modules.system.journal-shipping;
  # The k3s module is only imported on cluster nodes, so probe for the option.
  hasK3s = config.modules.system ? k3s && config.modules.system.k3s.enable;
in
{
  options.modules.system.journal-shipping = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.networking.hostName != "liveusb";
      defaultText = lib.literalExpression ''config.networking.hostName != "liveusb"'';
      description = "Ship this host's journal to VictoriaLogs.";
    };

    url = lib.mkOption {
      type = lib.types.str;
      default = if hasK3s then "http://10.43.169.2:9428" else "https://logs-ingest.k8s.rooty.dev";
      defaultText = lib.literalExpression ''
        if k3s then "http://10.43.169.2:9428" else "https://logs-ingest.k8s.rooty.dev"
      '';
      description = "Base URL of a VictoriaLogs ingest endpoint (…/insert/jsonline is appended).";
    };

    maxPriority = lib.mkOption {
      type = lib.types.ints.between 0 7;
      default = 6;
      description = ''
        Ship entries of this syslog priority or more severe. 6 (info) keeps
        debug lines, the bulk of a chatty unit's output, on the host.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf config.services.vector.enable {
      environment.persistence."/persist".directories = [
        {
          directory = "/var/lib/private/vector";
          mode = "0700";
        }
      ];
    })

    (lib.mkIf cfg.enable {
      services.vector = {
        enable = true;
        journaldAccess = true;
        settings = {
          sources.journal = {
            type = "journald";
            current_boot_only = false;
            since_now = true;
            # Vector's own errors (an unreachable endpoint, say) would otherwise
            # come back through this source and feed themselves.
            exclude_units = [ "vector.service" ];
          };

          transforms.journal_priority = {
            type = "filter";
            inputs = [ "journal" ];
            condition = "(to_int(.PRIORITY) ?? 6) <= ${toString cfg.maxPriority}";
          };

          sinks.victorialogs_journal = {
            type = "http";
            inputs = [ "journal_priority" ];
            uri = "${cfg.url}/insert/jsonline?_stream_fields=host,_SYSTEMD_UNIT&_msg_field=message&_time_field=timestamp";
            encoding.codec = "json";
            framing.method = "newline_delimited";
            compression = "gzip";
            # The ingest route caps a request at 16 MiB.
            batch = {
              max_bytes = 4194304;
              timeout_secs = 5;
            };
            # Spool while VictoriaLogs or the tailnet is away instead of
            # dropping; blocking only holds the reader back, and journald still
            # has the lines. Vector's minimum disk buffer is 256 MiB + 32 B.
            buffer = {
              type = "disk";
              max_size = 268435488;
              when_full = "block";
            };
            acknowledgements.enabled = true;
          };
        };
      };
    })
  ];
}
