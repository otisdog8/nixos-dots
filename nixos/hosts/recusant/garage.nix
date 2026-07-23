# Garage — single-node S3, shared by multiple tenants on this host.
#
# Tenancy model: one bucket per purpose, one access key per purpose, each key
# scoped read+write to ONLY its bucket. A leaked Attic push token can never
# touch backups, and vice versa. Buckets:
#   nix-cache     — Attic binary cache backend (key: attic-rw)     [in use]
#   velero        — k3s cluster backups (velero)                   [in use]
#   cnpg-backups  — k3s CloudNativePG WAL/base backups             [in use]
#   gitea-rgw     — k3s Gitea object storage                       [in use]
# The three k8s buckets are mirrored off-site to MEGA S4 with a read-only
# key (backup-sync-ro) — see s4-backups.nix.
#
# Exposure: the S3 API binds recusant's tailscale IP so both the local Attic
# server AND the k8s backup tenant on arquitens can reach it over the tailnet.
# tailscale0 is globally trusted (networking.nix), so nothing is opened to the
# LAN/WAN — no allowedTCPPorts needed. RPC/admin stay on loopback (single node,
# no remote consumer). An nginx vhost (bottom of this file) also fronts the S3
# API at https://garage.recusant.rooty.dev for a TLS endpoint with a stable
# hostname — still tailnet-only (nginx binds the tailscale IP).
#
# Durability note: replication_factor = 1 means no redundancy on the node
# itself. Fine for the regenerable nix-cache; the k8s buckets get their
# off-host copy via the daily rclone mirror to MEGA S4 (s4-backups.nix).
#
# The GARAGE_RPC_SECRET is sops-managed (secrets/garage.env) and read via
# systemd EnvironmentFile — no manual /persist file, so a rebuild alone brings
# Garage up. (EnvironmentFile is loaded by root before the DynamicUser drop, so
# the 0400 root secret is fine.)
#
# ── One-time bootstrap on recusant (after first rebuild with enable = true) ───
#   1. Layout (single node claims all capacity):
#        garage layout assign -z dc1 -c 1T <node-id-from `garage status`>
#        garage layout apply --version 1
#   2. nix-cache bucket + scoped key (feed the key into secrets/atticd.env):
#        garage bucket create nix-cache
#        garage key create attic-rw          # note the Key ID + Secret
#        garage bucket allow --read --write nix-cache --key attic-rw
#   3. Per-tenant buckets (velero/cnpg-backups/gitea-rgw) follow the same shape:
#        garage bucket create <bucket>
#        garage key create <tenant>-rw
#        garage bucket allow --read --write <bucket> --key <tenant>-rw
#      (Off-site mirroring of these adds a read-only key — see s4-backups.nix.)
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # recusant's tailscale IP — the same address the nginx vhosts pin to.
  tailscaleIp = "100.110.239.45";
in
{
  # RPC secret via sops → systemd EnvironmentFile (whole-file dotenv).
  sops.secrets."garage/env" = {
    format = "dotenv";
    sopsFile = ./secrets/garage.env;
    key = "";
    restartUnits = [ "garage.service" ];
  };

  services.garage = {
    enable = true;
    package = pkgs.garage;

    environmentFile = config.sops.secrets."garage/env".path;

    settings = {
      # Single-node setup
      replication_factor = 1;

      # Storage directories
      # Metadata on fast SSD (persisted via impermanence)
      metadata_dir = "/var/lib/garage/meta";
      # Data on bcachefs
      data_dir = "/mnt/bcachefs/garage/data";

      # Database engine - LMDB is recommended for performance
      db_engine = "lmdb";

      # Compression for stored blocks
      compression_level = 1;

      # RPC — single node, no remote peer, keep it on loopback.
      rpc_bind_addr = "127.0.0.1:3901";

      # S3 API — bound to the tailnet so local Attic + the k8s backup tenant on
      # arquitens can both reach it. Not exposed to LAN/WAN.
      s3_api = {
        api_bind_addr = "${tailscaleIp}:3900";
        s3_region = "garage";
      };

      # Admin API — loopback only (local `garage` CLI on this host).
      admin = {
        api_bind_addr = "127.0.0.1:3903";
      };
    };
  };

  # No allowedTCPPorts: the S3 API is bound to the tailscale IP and tailscale0
  # is a globally trusted interface, so the tailnet reaches 3900 without opening
  # it on any other interface. RPC/admin are loopback-only.

  # Persist the metadata dir. The module runs with DynamicUser, so state lives
  # at /var/lib/private/garage (systemd symlinks /var/lib/garage → it). Persist
  # the private path — NOT /var/lib/garage — or systemd can't create the symlink
  # over the bind mount ("Device or resource busy"). Same pattern as agent-auth.
  # metadata_dir = /var/lib/garage/meta resolves through the symlink into here.
  # (No user/group: the DynamicUser uid isn't known ahead of time.)
  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/private/garage";
      mode = "0700";
    }
  ];

  # data_dir lives on bcachefs, OUTSIDE systemd's StateDirectory. The module runs
  # garage as a DynamicUser and only adds the path to ReadWritePaths — systemd
  # won't create or chown it, and there's no static garage uid to own it. So:
  # give garage a stable supplementary group, and make the data dir setgid +
  # group-writable so the dynamic user can write blocks (metadata stays under the
  # StateDirectory, which systemd handles). tmpfiles needs the mount present, and
  # so does garage.
  #
  # NB the group must NOT be named "garage": DynamicUser mints a transient
  # user AND group both called "garage", and a static "garage" group collides
  # with it (systemd fails at step USER, "name already exists"). Hence
  # "garage-data".
  users.groups.garage-data = { };

  systemd.tmpfiles.rules = [
    "d /mnt/bcachefs/garage      0755 root root        - -"
    "d /mnt/bcachefs/garage/data 2770 root garage-data - -"
  ];

  systemd.services.garage = {
    unitConfig.RequiresMountsFor = [ "/mnt/bcachefs/garage/data" ];
    serviceConfig.SupplementaryGroups = [ "garage-data" ];
  };

  # ── TLS S3 endpoint ──────────────────────────────────────────────────────────
  # A friendly, TLS-terminated front for the S3 API. The raw API already answers
  # on the tailnet at ${tailscaleIp}:3900 (plaintext), which is how local Attic
  # and the arquitens backup tenant reach it. This vhost adds an HTTPS endpoint —
  # `garage.recusant.rooty.dev` — under the existing *.recusant.rooty.dev wildcard
  # cert (secrets.nix), so S3 clients can use a stable hostname with TLS instead
  # of a bare tailscale IP. Same shape as attic.nix / agent-auth.nix: nginx binds
  # the tailscale IP (server_name-matches within that exact-address socket), so
  # nothing is opened to LAN/WAN — reachable only over the tailnet.
  #
  # Path-style addressing: clients must NOT use virtual-hosted-style buckets
  # (bucket.garage.recusant.rooty.dev), since neither the wildcard cert nor this
  # vhost covers that extra label and Garage has no root_domain set. Point the S3
  # client at https://garage.recusant.rooty.dev with force_path_style = true.
  #
  # Host header is preserved (recommendedProxySettings → Host $host), so AWS
  # SigV4 signatures computed against garage.recusant.rooty.dev validate: Garage
  # recomputes with the same host it receives from nginx.
  services.nginx.virtualHosts."garage.recusant.rooty.dev" = {
    useACMEHost = "recusant.rooty.dev";
    forceSSL = true;
    listenAddresses = [ tailscaleIp ];
    locations."/" = {
      # The S3 API listens on the tailscale IP, not loopback — proxy there.
      proxyPass = "http://${tailscaleIp}:3900";
      extraConfig = ''
        # S3 object uploads can be large; don't let nginx cap or time them out.
        client_max_body_size 0;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
      '';
    };
  };
}
