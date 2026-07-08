# homelab-agent — Hermes instance #1: homelab ops agent.
#
# One zone per agent (see modules/apps/hermes-agents.nix): user/group
# homelab-agent, /var/lib/homelab-agent, its own Hindsight bank, its own
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
#        agent-auth admin agent-create homelab-agent \
#          --lldap-username svc-homelab-agent --description "Hermes homelab ops"
#      → copy the aa_... key ONCE into AGENT_AUTH_API_KEY below.
#   3. GitHub: mint a fine-grained PAT for the agent's machine account,
#      repo = nixos-dots only, permissions = contents:read + pull_requests:write.
#   4. Fill the env secrets:
#        sops nixos/hosts/recusant/secrets/homelab-agent.env
#          DISCORD_BOT_TOKEN=...
#          DISCORD_ALLOWED_CHANNELS=<ops channel id>
#          OPENROUTER_API_KEY=...          # aux/fallback models
#          FIRECRAWL_API_KEY=...           # web_search / web_extract
#          SCRAPFLY_API_KEY=...            # scrapfly MCP (anti-bot scraping)
#          HINDSIGHT_API_KEY=...           # = tenant key from hindsight.env
#          AGENT_AUTH_API_KEY=aa_...       # from step 2
#          GH_TOKEN=github_pat_...         # from step 3
#   5. Rebuild, then Codex OAuth (device-code; hermes imports ~/.codex/auth.json):
#        sudo -u homelab-agent env HOME=/var/lib/homelab-agent codex auth login
#        systemctl restart hermes-homelab-agent
#   6. Verify: @mention the bot in the ops channel; first tool call against
#      agent-auth should be list_capabilities. Dashboard rides
#      https://homelab-agent.recusant.rooty.dev (tailnet; public path gets
#      forward-auth at the k8s ingress before it ever reaches nginx here).
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
  sops.secrets."homelab-agent/env" = {
    format = "dotenv";
    sopsFile = ./secrets/homelab-agent.env;
    key = "";
    restartUnits = [
      "hermes-homelab-agent.service"
      "hermes-homelab-agent-dashboard.service"
    ];
  };

  # ── The agent ──────────────────────────────────────────────────────────────
  modules.apps.hermes-agents.instances.homelab-agent = {
    environmentFiles = [ config.sops.secrets."homelab-agent/env".path ];

    # Non-secret env. Hindsight is the shared service in ./hindsight.nix;
    # the bank is this agent's private memory namespace.
    environment = {
      HINDSIGHT_MODE = "local_external";
      HINDSIGHT_API_URL = "http://127.0.0.1:8888";
      HINDSIGHT_BANK_ID = "homelab-agent";
    };

    # On the shell-tool PATH: local headless-Chromium browser automation
    # (hermes routes browser tools through agent-browser when it's present),
    # gh for the PR escape valve, agent-auth-mcp for the broker. chromium
    # rides along for agent-browser to drive; if it refuses the system
    # chromium, the one-time imperative fallback is
    # `sudo -u homelab-agent env HOME=/var/lib/homelab-agent agent-browser install`
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
    };

    settings = {
      # ChatGPT subscription via Codex OAuth (manual login, bootstrap step 5).
      # Auxiliary tasks stay on "auto": they pick codex/openrouter from
      # whatever auth is present, so the OpenRouter key doubles as fallback.
      model = {
        provider = "codex";
        default = "gpt-5.3-codex";
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

  # ── Dashboard vhost ────────────────────────────────────────────────────────
  # Serving chain (jellyfin/sab pattern): public DNS → k8s ingress (forward
  # auth, arquitens) → tailnet → this nginx → 127.0.0.1:9119. The dashboard
  # has no auth gate on a loopback bind, so nginx listens ONLY on the
  # tailscale IP — LAN gets connection-refused, not a login page.
  services.nginx.virtualHosts."homelab-agent.recusant.rooty.dev" = {
    useACMEHost = "recusant.rooty.dev";
    forceSSL = true;
    listenAddresses = [ tailscaleIp ];
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString dashboardPort}";
      proxyWebsockets = true; # /api/ws chat + /api/pty terminal
    };
  };

  # Let nginx bind the tailscale IP before tailscaled has brought the
  # interface up at boot (otherwise nginx fails and needs a restart).
  boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;
}
