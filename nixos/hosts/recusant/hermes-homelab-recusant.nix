# hermes-homelab-recusant — Hermes instance #1: homelab ops agent.
#
# One zone per agent (see modules/apps/hermes-agents.nix): user/group
# hermes-homelab-recusant, /var/lib/hermes-homelab-recusant, its own Hindsight bank, its own
# Discord channel, its own agent-auth identity. Adding the next agent is a new
# `instances.<name>` block + sops env + bank + channel, not a new deployment.
#
# Security model (the parts that matter):
#   - Policy is Nix: model routing, tools, channels, MCP list all live in the
#     read-only store — a prompt-injected agent cannot self-grant capabilities.
#   - Knowledge is the agent's: memory (Hindsight), skills, sessions live in
#     the zone and evolve freely (skill WRITES are approval-gated, below).
#   - Credentials are brokered: infra creds come from agent-auth per-use with
#     Discord approval; the only resident tokens are narrowly scoped (PR-only
#     GitHub PAT) or subscription OAuth stores.
#   - Config changes: the agent proposes a PR to nixos-dots (PAT can NOT push
#     to master); a human merges and rebuilds.
#
# ── One-time bootstrap ────────────────────────────────────────────────────────
#   1. Discord: create the bot (MESSAGE CONTENT intent on), invite it to the
#      server, note the ops channel ID. The agent answers @mentions in that
#      one channel only (DISCORD_ALLOWED_CHANNELS); exec/skill approvals
#      appear there too.
#   2. agent-auth identity (broker runs on this host — see agent-auth.nix):
#        agent-auth admin agent-create hermes-homelab-recusant \
#          --lldap-username svc-hermes-homelab-recusant --description "Hermes homelab ops"
#      → copy the aa_... key ONCE into AGENT_AUTH_API_KEY below.
#   3. GitHub: mint a fine-grained PAT for the agent's machine account,
#      repo = nixos-dots only, permissions = contents:read + pull_requests:write.
#   4. Fill the env secrets:
#        sops nixos/hosts/recusant/secrets/hermes-homelab-recusant.env
#          DISCORD_BOT_TOKEN=...
#          DISCORD_ALLOWED_CHANNELS=<ops channel id>
#          OPENROUTER_API_KEY=...          # aux/fallback models
#          FIRECRAWL_API_KEY=...           # web_search / web_extract
#          SCRAPFLY_API_KEY=...            # scrapfly MCP (anti-bot scraping)
#          HINDSIGHT_API_KEY=...           # = tenant key from hindsight.env
#          AGENT_AUTH_API_KEY=aa_...       # from step 2
#          GH_TOKEN=github_pat_...         # from step 3
#   5. Rebuild, then Codex OAuth (device-code; hermes imports ~/.codex/auth.json):
#        sudo -u hermes-homelab-recusant env HOME=/var/lib/hermes-homelab-recusant codex auth login
#        systemctl restart hermes-homelab-recusant
#   6. Verify: @mention the bot in the ops channel; first tool call against
#      agent-auth should be list_capabilities. Dashboard: public name is
#      https://homelab-agent-recusant.rooty.dev (k8s ingress, forward-auth);
#      the vhost here is only the stable internal origin k8s forwards to.
{
  config,
  inputs,
  pkgs,
  ...
}:
let
  # Only the MCP client entrypoint out of the broker venv — its bin/ carries
  # generic console scripts (fastapi, alembic, ...) that would shadow real
  # packages on the agent's PATH (same trick as modules/apps/agent-auth-client.nix).
  agentAuthMcp = pkgs.runCommand "agent-auth-mcp-client" { } ''
    mkdir -p $out/bin
    ln -s ${
      inputs.agent-auth.packages.${pkgs.stdenv.hostPlatform.system}.default
    }/bin/agent-auth-mcp $out/bin/agent-auth-mcp
  '';

  # recusant's tailnet address. nginx below binds this instead of 0.0.0.0 so
  # the (auth-less) dashboard is unreachable from LAN/WAN at the socket layer.
  tailscaleIp = "100.110.239.45";

  dashboardPort = 9119;
in
{
  # ── Secrets ────────────────────────────────────────────────────────────────
  sops.secrets."hermes-homelab-recusant/env" = {
    format = "dotenv";
    sopsFile = ./secrets/hermes-homelab-recusant.env;
    key = "";
    restartUnits = [
      "hermes-homelab-recusant.service"
      "hermes-homelab-recusant-dashboard.service"
    ];
  };

  # ── The agent ──────────────────────────────────────────────────────────────
  modules.apps.hermes-agents.instances.hermes-homelab-recusant = {
    environmentFiles = [ config.sops.secrets."hermes-homelab-recusant/env".path ];

    # Non-secret env. Hindsight is the shared service in ./hindsight.nix;
    # the bank is this agent's private memory namespace.
    environment = {
      HINDSIGHT_MODE = "local_external";
      HINDSIGHT_API_URL = "http://127.0.0.1:8888";
      HINDSIGHT_BANK_ID = "hermes-homelab-recusant";
    };

    # On the shell-tool PATH: local headless-Chromium browser automation
    # (hermes routes browser tools through agent-browser when it's present),
    # gh for the PR escape valve, agent-auth-mcp for the broker. chromium
    # rides along for agent-browser to drive; if it refuses the system
    # chromium, the one-time imperative fallback is
    # `sudo -u hermes-homelab-recusant env HOME=/var/lib/hermes-homelab-recusant agent-browser install`
    # (lands in the persisted home, like the codex login).
    extraPackages = [
      agentAuthMcp
      pkgs.agent-browser
      pkgs.chromium
      pkgs.gh
    ];

    dashboard = {
      enable = true;
      port = dashboardPort;
      # Non-loopback bind engages the dashboard's auth gate (fails closed
      # without a provider) — auth comes from the Authelia OIDC block in
      # settings below, so even direct tailnet access gets a login page.
      host = tailscaleIp;
    };

    settings = {
      # ChatGPT subscription via Codex OAuth (manual login, bootstrap step 5).
      # Auxiliary tasks stay on "auto": they pick codex/openrouter from
      # whatever auth is present, so the OpenRouter key doubles as fallback.
      # Codex-backend slugs at the pinned rev: gpt-5.5, gpt-5.4[-mini],
      # gpt-5.3-codex, gpt-5.3-codex-spark (Pro-only preview; /model to try).
      model = {
        provider = "codex";
        default = "gpt-5.5";
      };

      # One server channel, @mention-gated; channel allowlist comes from
      # DISCORD_ALLOWED_CHANNELS in the sops env (env overrides config.yaml).
      discord = {
        require_mention = true;
        thread_require_mention = false;
      };

      web = {
        search_backend = "firecrawl";
        extract_backend = "firecrawl";
      };

      memory.provider = "hindsight";

      # The authority users actually see (Cloudflare → k8s ingress). With
      # multiple proxy hops, header reconstruction is fragile — pin it so the
      # dashboard builds links/redirects (incl. the OIDC redirect_uri
      # <public_url>/auth/callback) against the public name.
      dashboard.public_url = "https://hermes-homelab-recusant.rooty.dev";

      # Auth gate: Authelia via the bundled self-hosted OIDC plugin. Public
      # PKCE client — no client secret (confidential clients unsupported).
      # The Authelia side (k8s) must register the matching client; see the
      # OIDC handoff notes in this file's history / k8s repo.
      dashboard.oauth = {
        provider = "self-hosted";
        self_hosted = {
          issuer = "https://auth.rooty.dev"; # Authelia root — must match its discovery document
          client_id = "hermes-homelab-recusant";
          scopes = "openid profile email";
        };
      };

      # Skills are the agent's persistence layer — exactly where a prompt
      # injection would try to survive a restart. Stage writes for review
      # (/skills pending|diff|approve from the ops channel). Memory writes
      # stay free; Hindsight banks are reviewable after the fact.
      skills.write_approval = true;

      # ${VAR} placeholders resolve from $HERMES_HOME/.env at runtime, so the
      # store-side config.yaml never contains a secret.
      mcp_servers = {
        # Credential broker (../agent-auth.nix). The tool descriptions teach
        # the request → wait → retry/escalate protocol; grants get human
        # approval in Discord on the broker side.
        agent-auth = {
          command = "agent-auth-mcp";
          env = {
            AGENT_AUTH_URL = "http://127.0.0.1:${toString config.services.agent-auth.port}";
            AGENT_AUTH_API_KEY = "\${AGENT_AUTH_API_KEY}";
          };
        };
        # Hosted anti-bot scraping — heavy/public scraping goes here instead
        # of the local browser.
        scrapfly = {
          url = "https://mcp.scrapfly.io/mcp?apiKey=\${SCRAPFLY_API_KEY}";
        };
      };
    };
  };

  # ── Dashboard vhost (internal origin) ──────────────────────────────────────
  # Serving chain (jellyfin/sab pattern):
  #   homelab-agent-recusant.rooty.dev            — public, k8s ingress + forward-auth
  #     → hermes-homelab-recusant.recusant.rooty.dev — THIS vhost: stable internal
  #       DNS for k8s to forward to over the tailnet (*.recusant.rooty.dev is
  #       internal-only naming)
  #       → 127.0.0.1:9119
  # The dashboard has no auth gate on a loopback bind, so nginx listens ONLY
  # on the tailscale IP — LAN gets connection-refused, not a login page.
  services.nginx.virtualHosts."hermes-homelab-recusant.recusant.rooty.dev" = {
    useACMEHost = "recusant.rooty.dev";
    forceSSL = true;
    listenAddresses = [ tailscaleIp ];
    locations."/" = {
      proxyPass = "http://${tailscaleIp}:${toString dashboardPort}";
      proxyWebsockets = true; # /api/ws chat + /api/pty terminal
      # The dashboard's Host-header (DNS-rebinding) guard on a non-loopback
      # bind requires Host == the bind address; the recommended settings
      # would forward the public hostname (proxy_set_header Host $host) and
      # draw a 400 "Invalid Host header". With them off, nginx's default
      # Host is $proxy_host (the tailscale IP:port), which the guard
      # accepts. The public authority still reaches the app via
      # X-Forwarded-* below and the pinned dashboard.public_url.
      recommendedProxySettings = false;
      extraConfig = ''
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
      '';
    };
  };

  # Let nginx bind the tailscale IP before tailscaled has brought the
  # interface up at boot (otherwise nginx fails and needs a restart).
  boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;
}
