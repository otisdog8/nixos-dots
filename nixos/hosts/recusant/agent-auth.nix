# agent-auth — credential broker for AI agents (https://github.com/uorux/agent-auth).
#
# Runs here (not on the k8s cluster) deliberately: on k8s the gitops repo
# configures the broker, and a brokered agent with gitops access could
# self-escalate. On recusant the policy is in the read-only nix store and every
# change is a commit to THIS repo + a rebuild. The corollary rule: no brokered
# agent may ever get push access to nixos-dots.
#
# The upstream nixosModule provides the hardened systemd unit (DynamicUser,
# self-migrating SQLite in /var/lib/agent-auth, WAL mode). This file wires in:
# policy from the nix store, secrets via sops, TLS via nginx + a dedicated
# ACME cert, and impermanence for the database.
#
# ── One-time bootstrap ────────────────────────────────────────────────────────
#   1. Discord: create the bot (no privileged intents), invite it, note the
#      approvals channel ID + your user ID.
#   2. GitHub App (github.com/settings/apps): no webhook; grant the ceiling
#      mirrored in agent-auth-policy.yaml (contents/workflows/secrets/
#      variables/PRs/issues rw, actions/checks read, plus org secrets/
#      variables rw + self-hosted-runners read on @uorux). Install it on
#      otisdog8, uorux, rooty-dev, and rootyorg; generate the PEM, note
#      App ID + installation ID.
#   3. Fill the env secrets:
#        nix shell nixpkgs#sops
#        sops nixos/hosts/recusant/secrets/agent-auth.env
#   4. GitHub PEM + k8s provisioner token are binary sops files under
#      ./secrets/ (k8s: RBAC from the agent-auth repo's deploy/k8s.yaml —
#      ServiceAccount + ClusterRoles + a cluster-wide ClusterRoleBinding — and
#      a long-lived token Secret for the agent-auth SA; the cluster CA is the
#      plain ./agent-auth-k8s-ca.pem). To rotate: re-encrypt with sops, and
#      for k8s re-mint the token Secret first.
#   5. DNS: make agent-auth.recusant.rooty.dev resolve to recusant (however
#      the other *.recusant.rooty.dev names do). nginx only listens usefully
#      on the tailnet — the firewall doesn't open 443 to the world, which is
#      fine: agents live on the tailnet too.
#   6. Rebuild, then onboard each Hermes instance:
#        agent-auth admin agent-create <name> --lldap-username svc-<name>
#      and walk scripts/e2e.py once against the live Discord channel.
{
  config,
  inputs,
  ...
}:
{
  imports = [ inputs.agent-auth.nixosModules.default ];

  # ── Secrets ────────────────────────────────────────────────────────────────
  # Whole-file dotenv (key = "" means "the entire file is the secret").
  # sops base config (defaultSopsFile + host age key) lives in ./minecraft.nix.
  sops.secrets."agent-auth/env" = {
    format = "dotenv";
    sopsFile = ./secrets/agent-auth.env;
    key = "";
    restartUnits = [ "agent-auth.service" ]; # bounce on rotation
  };

  # Binary file credentials (GitHub App PEM, k8s provisioner SA token).
  sops.secrets."agent-auth/github-pem" = {
    format = "binary";
    sopsFile = ./secrets/agent-auth-github.pem;
    restartUnits = [ "agent-auth.service" ];
  };
  sops.secrets."agent-auth/k8s-token" = {
    format = "binary";
    sopsFile = ./secrets/agent-auth-k8s-token;
    restartUnits = [ "agent-auth.service" ];
  };

  # ── The broker ─────────────────────────────────────────────────────────────
  services.agent-auth = {
    enable = true;
    policyFile = ./agent-auth-policy.yaml; # → nix store, immutable
    environmentFiles = [ config.sops.secrets."agent-auth/env".path ];
    # File secrets via systemd LoadCredential; referenced below at
    # /run/credentials/agent-auth.service/<name>.
    loadCredentials = [
      "github-pem:${config.sops.secrets."agent-auth/github-pem".path}"
      "k8s-token:${config.sops.secrets."agent-auth/k8s-token".path}"
    ];
    # Non-secret environment. Secrets live in the sops env file; these are
    # paths and endpoints, kept here because the CA's nix-store path can't be
    # known from inside the env file anyway.
    settings = {
      GITHUB_APP_PRIVATE_KEY_FILE = "/run/credentials/agent-auth.service/github-pem";
      # k3s API servers — all three control-plane nodes (tailnet), comma-
      # separated so the broker fails over when one is down (upstream c6e937b).
      # The provisioner tries each in turn on transport error and promotes
      # whichever answers. Same cluster CA + shared tls-san list validates all
      # three (see modules/system/k3s: --tls-san for each node IP). Order:
      # arquitens first (historical primary), then carrack, then munificent.
      KUBERNETES_API_URL = "https://100.126.30.73:6443,https://100.103.225.29:6443,https://100.65.16.13:6443";
      KUBERNETES_TOKEN_FILE = "/run/credentials/agent-auth.service/k8s-token";
      # k3s cluster CA (public, nix store is fine) — the API cert is not
      # signed by anything in the system trust store.
      KUBERNETES_CA_FILE = "${./agent-auth-k8s-ca.pem}";
    };
  };

  # SQLite (WAL) lives in /var/lib/agent-auth → /var/lib/private/agent-auth
  # under DynamicUser. Root is ephemeral on this host, so persist it (requests,
  # grants, and the audit trail must survive reboots — expiry-on-boot depends
  # on re-reading the grants table).
  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/private/agent-auth";
      mode = "0700";
    }
  ];

  # ── TLS + reverse proxy ────────────────────────────────────────────────────
  # Covered by the existing *.recusant.rooty.dev wildcard cert (secrets.nix),
  # same as the other services on this host.
  services.nginx.virtualHosts."agent-auth.recusant.rooty.dev" = {
    useACMEHost = "recusant.rooty.dev";
    forceSSL = true;
    # agent-auth.recusant.rooty.dev resolves to the tailscale IP, and other
    # vhosts (hermes/sab/jellyfin) listen on it exactly — nginx only
    # server_name-matches within the exact-address socket, so this vhost must
    # join it or the hermes dashboard answers instead (see media.nix).
    listenAddresses = [ "100.110.239.45" ];
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.agent-auth.port}";
      extraConfig = ''
        # Long-polls clamp to 300s server-side: /v1/requests/{id}/wait and the
        # a2a reads (/v1/a2a/threads/{id}/messages?wait, /v1/a2a/events?wait).
        # Keep nginx above that ceiling so a full-length park returns cleanly
        # instead of racing the read timeout into a 504.
        proxy_read_timeout 330s;
      '';
    };
  };
}
