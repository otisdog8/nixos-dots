# Attic — self-hosted Nix binary cache, backed by the local Garage S3.
#
# Purpose (current scope: CI only): the self-hosted runners on the arquitens
# k3s cluster build our NixOS configs / custom packages, and PUSH+PULL the
# closures here via attic-action so CI runs reuse prebuilt paths. The cache is
# PRIVATE (token-gated reads) — runners authenticate per-job with a token, so it
# is never made --public. Fleet-wide pulling (workstations pulling as a plain
# substituter) is intentionally NOT wired yet; that would need a pull token
# distributed to each host (sops is currently only set up on recusant).
#
# Shape (mirrors agent-auth.nix): native NixOS service on recusant, listening on
# loopback, fronted by nginx on the tailscale IP under the *.recusant.rooty.dev
# wildcard cert. Runners reach it over the tailnet exactly like they reach the
# k3s API. Storage is the `nix-cache` Garage bucket (see garage.nix); Attic talks
# to Garage over the tailnet-bound S3 API. Secrets (RS256 signing key + S3
# access key) come from a sops env file, never the store.
#
# ── One-time bootstrap ────────────────────────────────────────────────────────
#   1. Do the Garage bootstrap in garage.nix first (bucket `nix-cache` + key
#      `attic-rw`). Note the key's Key ID + Secret.
#   2. Generate the RS256 signing secret and fill the sops env file:
#        nix shell nixpkgs#sops nixpkgs#openssl
#        openssl genrsa -traditional 4096 | base64 -w0    # -> RS256 secret
#        sops nixos/hosts/recusant/secrets/atticd.env
#          ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=<the base64 above>
#          AWS_ACCESS_KEY_ID=<attic-rw Key ID>
#          AWS_SECRET_ACCESS_KEY=<attic-rw Secret>
#   3. Rebuild recusant. Mint a CI push token (scoped push+pull to nix-cache):
#        atticd-atticadm make-token --sub ci --validity '10y' \
#          --pull nix-cache --push nix-cache
#      Store that token as a GitHub Actions secret (route it through agent-auth's
#      secret flow rather than pasting by hand).
#   4. From a workstation, create the (private) cache:
#        attic login recusant https://attic.recusant.rooty.dev <admin-token>
#        attic cache create nix-cache
#      Leave it private — do NOT `attic cache configure nix-cache --public`.
#      `attic cache info nix-cache` prints the public signing key; you only need
#      it if you later wire fleet-wide substituter pulls (not done today — see
#      the purpose note above). CI uses the push token from step 3 via
#      attic-action, which configures the substituter + netrc inside each job.
{
  config,
  ...
}:
let
  tailscaleIp = "100.110.239.45"; # recusant's tailscale IP (matches the vhosts)
in
{
  # ── Secret ─────────────────────────────────────────────────────────────────
  # Whole-file dotenv (key = "" means "the entire file is the secret"): holds
  # ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64 + the Garage S3 access key. sops base
  # config (defaultSopsFile + host age key) lives in ./minecraft.nix.
  sops.secrets."atticd/env" = {
    format = "dotenv";
    sopsFile = ./secrets/atticd.env;
    key = "";
    restartUnits = [ "atticd.service" ]; # bounce on rotation
  };

  # ── The cache server ───────────────────────────────────────────────────────
  services.atticd = {
    enable = true;
    environmentFile = config.sops.secrets."atticd/env".path;
    settings = {
      # Loopback; nginx terminates TLS on the tailnet and proxies here. NB: 8080
      # is taken by sabnzbd (media.nix) — using it here proxied attic straight
      # into sab. Keep this clear of that port.
      listen = "127.0.0.1:8091";

      # SQLite is fine single-node; state persisted below. (default url)
      # database.url = "sqlite:///var/lib/atticd/server.db?mode=rwc";

      # S3 backend = the local Garage `nix-cache` bucket. Credentials come from
      # AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in the sops env file. The
      # endpoint is Garage's tailnet-bound S3 API (loopback won't answer).
      storage = {
        type = "s3";
        region = "garage";
        bucket = "nix-cache";
        endpoint = "http://${tailscaleIp}:3900";
      };

      # Content-defined chunking → global dedup across pushes (module defaults).
      chunking = {
        nar-size-threshold = 65536;
        min-size = 16384;
        avg-size = 65536;
        max-size = 262144;
      };
    };
  };

  # SQLite server.db lives in /var/lib/atticd; root is ephemeral on this host,
  # so persist it (cache metadata / GC state must survive reboots).
  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/atticd";
      user = config.services.atticd.user;
      group = config.services.atticd.group;
      mode = "0700";
    }
  ];

  # ── TLS + reverse proxy ────────────────────────────────────────────────────
  # Covered by the existing *.recusant.rooty.dev wildcard cert (secrets.nix).
  services.nginx.virtualHosts."attic.recusant.rooty.dev" = {
    useACMEHost = "recusant.rooty.dev";
    forceSSL = true;
    # Join the tailscale-IP socket the other vhosts use (see media.nix / the
    # note in agent-auth.nix): nginx server_name-matches within the exact-address
    # socket, so this vhost must bind the same address.
    listenAddresses = [ tailscaleIp ];
    locations."/" = {
      proxyPass = "http://127.0.0.1:8091";
      extraConfig = ''
        # NAR uploads from CI can be large; don't let nginx cap or time them out.
        client_max_body_size 0;
        proxy_read_timeout 300s;
      '';
    };
  };
}
