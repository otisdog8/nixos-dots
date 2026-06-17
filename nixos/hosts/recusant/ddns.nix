# Dynamic DNS for pdx-1.rooty.dev (Cloudflare).
#
# recusant sits behind a dynamic residential IP. `cloudflare-dyndns` resolves
# the host's current public IPv4 and updates the A record for pdx-1.rooty.dev
# every 5 minutes (systemd timer; see `frequency`). DNS-only (not proxied), so
# the record points straight at the box for direct connections (SSH, game
# servers, etc.).
#
# The API token is a raw secret managed by sops-nix. In this nixpkgs the module
# loads it via systemd LoadCredential and expects JUST the token (NOT the legacy
# `CLOUDFLARE_API_TOKEN=...` env form — it errors out on that), so we point
# apiTokenFile straight at the decrypted sops secret. sops base config
# (defaultSopsFile + host age key) is declared in ./minecraft.nix.
#
# ── One-time bootstrap on recusant ───────────────────────────────────────────
#   1. Create a Cloudflare API token (or reuse an existing rooty.dev DNS token)
#      with Zone:DNS:Edit + Zone:Zone:Read scoped to the rooty.dev zone:
#        https://dash.cloudflare.com/profile/api-tokens
#   2. Add it to the host sops file (value is the bare token, no prefix):
#        nix shell nixpkgs#sops
#        sops nixos/hosts/recusant/secrets/recusant.yaml
#        #   cloudflare-ddns-api-token: <token>
#   3. Ensure the A record pdx-1.rooty.dev exists in Cloudflare (the tool updates
#      an existing record; create a placeholder A record first if it doesn't).
{
  config,
  ...
}:
{
  sops.secrets."cloudflare-ddns-api-token" = { };

  services.cloudflare-dyndns = {
    enable = true;
    domains = [ "pdx-1.rooty.dev" ];
    apiTokenFile = config.sops.secrets."cloudflare-ddns-api-token".path;
    ipv4 = true;
    ipv6 = false; # No IPv6 AAAA record; flip on if recusant gets a stable v6.
    proxied = false; # DNS-only — point directly at the box, not Cloudflare's edge.
  };
}
