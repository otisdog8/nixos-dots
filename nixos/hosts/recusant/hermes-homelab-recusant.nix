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
#          DISCORD_ALLOWED_USERS=<your discord user id>  # comma-separated;
#            user authz is default-DENY — without this every sender gets
#            "Unauthorized user", even in an allowed channel
#          DISCORD_HOME_CHANNEL=<ops channel id>  # proactive output (cron,
#            reminders). The gateway tries to self-persist this on first
#            contact and managed mode refuses — set it here instead.
#          OPENROUTER_API_KEY=...          # aux/fallback models
#          FIRECRAWL_API_KEY=...           # web_search / web_extract
#          SCRAPFLY_API_KEY=...            # scrapfly MCP (anti-bot scraping)
#          HINDSIGHT_API_KEY=...           # = tenant key from hindsight.env
#          AGENT_AUTH_API_KEY=aa_...       # from step 2
#          GH_TOKEN=github_pat_...         # from step 3
#   5. Rebuild, then Codex OAuth into HERMES' OWN auth store (device-code —
#      a plain `codex login` is NOT enough, the gateway logs "No Codex
#      credentials stored" until this runs):
#        sudo -u hermes-homelab-recusant -i hermes auth add codex-oauth
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
        provider = "openai-codex";
        default = "gpt-5.5";
      };

      # One server channel, @mention-gated; channel allowlist comes from
      # DISCORD_ALLOWED_CHANNELS in the sops env (env overrides config.yaml).
      discord = {
        require_mention = true;
        thread_require_mention = false;
        # Ping allowed Discord users when command-approval prompts are posted.
        approval_mentions = true;
      };

      web = {
        search_backend = "firecrawl";
        extract_backend = "firecrawl";
      };

      # Allow the Alertmanager cron triage job to open the known-good local
      # homelab endpoint without blocking on Tirith's generic .dev lookalike-TLD
      # warning. Keep this narrow: only the local browser command for this host,
      # not all .dev URLs or all cron approvals.
      command_allowlist = [
        "agent-browser open https://alertmanager.rooty.dev*"
      ];

      # Webhooks default to Hermes' constrained `hermes-webhook` toolset
      # (web/vision/clarify only) because arbitrary third-party webhook payloads
      # are untrusted. This instance exposes only the HMAC-protected agent-auth
      # a2a-dispatch route, so opt that platform into the local operational
      # tools homelab delegates need: terminal for `agent-browser`, file for
      # temporary browser probe snippets, skills for cold-session runbook loads,
      # and the usual state/context helpers. MCP servers such as agent-auth are
      # still included by default.
      platform_toolsets.webhook = [
        "web"
        "terminal"
        "file"
        "skills"
        "memory"
        "session_search"
        "todo"
        "clarify"
      ];

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

      # This agent maintains homelab runbooks as skills. Keep skill writes
      # enabled without staging so operational fixes do not require a manual
      # approval round-trip for every update. Secrets still stay out of skills.
      skills.write_approval = false;

      # agent-auth a2a dispatch: the broker POSTs thread-open events here, then
      # Hermes accepts the a2a thread and replies over agent-auth. Seed the
      # homelab ops runbook as this agent's baseline, and make the prompt tell
      # cold webhook sessions to load any additional task-specific skills.
      platforms.webhook = {
        enabled = true;
        extra = {
          host = "127.0.0.1";
          port = 8644;
          routes.a2a-dispatch = {
            deliver = "discord";
            deliver_extra.chat_id = "1524682829999636571";
            skills = [ "homelab-ops" ];
            prompt = ''
              You are a Hermes worker serving ONE agent-to-agent (a2a) request routed through
              the agent-auth broker. You have the agent-auth MCP tools.

              Peer agent: {peer}
              a2a thread id: {thread_id}
              Topic: {topic}
              The peer's opening request (JSON): {payload}

              Skill and memory preflight — do before substantive work:

              - This is a cold webhook session. Do not assume it inherited skills or chat
                history from Discord or any previous a2a run.
              - Read the peer request and topic, then explicitly load relevant runbooks with
                skill_view before planning or acting. If unsure which skill applies, call
                skills_list and then skill_view for the best matches.
              - The homelab-ops skill is preloaded as a baseline for this agent, but still
                load additional task-specific skills when useful. Common mappings:
                  * Hermes configuration/webhooks/gateway/tools/skills → hermes-agent
                  * GitHub PR/repo work → github-pr-workflow and/or github-auth
                  * Kubernetes/GitOps/Authelia/LLDAP/Gitea/homelab apps → homelab-ops
                  * debugging code/tests → systematic-debugging or test-driven-development
              - Use persistent memory as background facts, not as a substitute for skills:
                memory is compact and may not contain full procedures. Prefer skill_view for
                operational steps, commands, and pitfalls.
              - If the loaded skills say a credential, human approval, password, 2FA, secret
                material, or risky side effect is needed, pause and communicate that blocker
                over the a2a thread rather than guessing.

              Protocol — follow exactly, using the agent-auth MCP tools:

              1. Call create_session (label "a2a-{peer}"). Remember the returned session_id;
                 call it S, and pass session_key=S on EVERY agent-auth call below.

              2. Call a2a_accept with thread_id "{thread_id}" and session_key=S to claim the
                 thread. If it fails because the thread is already accepted or closed, another
                 worker already took it: call close_session (session_key=S) and STOP.

              3. Do what {peer} asked. If you need a credential or capability, call
                 request_access with on_behalf_of_thread="{thread_id}" and session_key=S,
                 citing ONLY this thread. Wait for approval as the tool instructs.

              4. Talk to {peer} ONLY over the a2a thread:
                   send:    a2a_send  thread_id="{thread_id}", payload=<json>, session_key=S
                   receive: a2a_poll  thread_id="{thread_id}", wait=300, session_key=S
                 A parked a2a_poll also keeps your session alive — keep polling while you
                 await replies.

              5. When finished, do these IN ORDER (a send after close fails):
                   a. a2a_send a final result:
                      {"type":"result","status":"done"|"failed"|"declined","summary":"<one paragraph>","detail":{}}
                      (thread_id="{thread_id}", session_key=S)
                   b. a2a_close thread_id="{thread_id}", reason matching the status, session_key=S
                   c. close_session (session_key=S)

              The a2a thread is the ONLY channel {peer} sees. This Discord post is human
              observability only — never rely on it to reach {peer}; the authoritative result
              goes to the thread via a2a_send.
            '';
          };
        };
      };

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
        # of the local browser. Bearer-header auth per Scrapfly's MCP docs
        # (query-param auth is their local-dev path and doesn't reliably
        # work against the hosted server).
        scrapfly = {
          url = "https://mcp.scrapfly.io/mcp";
          headers = {
            Authorization = "Bearer \${SCRAPFLY_API_KEY}";
          };
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

  # The dashboard verifies OIDC logins server-side (discovery, JWKS, token
  # exchange) against https://auth.rooty.dev — which Cloudflare fronts, and
  # Cloudflare 403s PyJWT's Python-urllib user agent. Pin the name to the
  # k8s ingress on arquitens so those fetches ride the tailnet instead:
  # same hostname (issuer/iss validation unchanged), valid LE cert
  # (*.rooty.dev SAN), no Cloudflare in the path. Verified 2026-07-08:
  # python TLS handshake + jwks.json 200 via this route. If the ingress
  # ever moves off arquitens, update this IP.
  networking.hosts."100.126.30.73" = [ "auth.rooty.dev" ];
}
