# Garage — single-node S3, shared by multiple tenants on this host.
#
# Tenancy model: one bucket per purpose, one access key per purpose, each key
# scoped read+write to ONLY its bucket. A leaked Attic push token can never
# touch backups, and vice versa. Buckets:
#   nix-cache    — Attic binary cache backend (key: attic-rw)      [in use]
#   k8s-backups  — future backup target for the k3s cluster        [reserved]
#                  (velero/restic/k8up on arquitens; not wired yet)
#
# Exposure: the S3 API binds recusant's tailscale IP so both the local Attic
# server AND the k8s backup tenant on arquitens can reach it over the tailnet.
# tailscale0 is globally trusted (networking.nix), so nothing is opened to the
# LAN/WAN — no allowedTCPPorts needed. RPC/admin stay on loopback (single node,
# no remote consumer).
#
# Durability note: replication_factor = 1 means no redundancy. Fine for the
# regenerable nix-cache; when k8s-backups is wired, add off-host replication —
# recusant is a single point of failure for anything stored here.
#
# ── One-time bootstrap on recusant (after first rebuild with enable = true) ───
#   1. RPC secret (if /persist/garage.env is empty):
#        echo "GARAGE_RPC_SECRET=$(openssl rand -hex 32)" > /persist/garage.env
#   2. Layout (single node claims all capacity):
#        garage layout assign -z dc1 -c 1T <node-id-from `garage status`>
#        garage layout apply --version 1
#   3. nix-cache bucket + scoped key (feed the key into secrets/atticd.env):
#        garage bucket create nix-cache
#        garage key create attic-rw          # note the Key ID + Secret
#        garage bucket allow --read --write nix-cache --key attic-rw
#   4. k8s-backups: create the bucket + its own key ONLY when wiring backups:
#        garage bucket create k8s-backups
#        garage key create k8s-backup-rw
#        garage bucket allow --read --write k8s-backups --key k8s-backup-rw
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
  services.garage = {
    enable = true;
    package = pkgs.garage;

    environmentFile = "/persist/garage.env";

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

  # Persistence for metadata directory
  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/garage";
      user = "garage";
      group = "garage";
      mode = "0700";
    }
  ];
}
