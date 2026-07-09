# hermes-a2a — agent-to-agent (a2a) serving for hermes-homelab-recusant.
#
# Lets other agents (Claude Code, Codex, other Hermes instances) open a2a threads
# TO this Hermes and have it work them as a responder. Two halves, both here:
#
#   1. DISPATCHER (this host): a resident, sessionless loop —
#        agent-auth a2a serve --on-open-url <hermes-webhook>
#      It long-polls the broker's /v1/a2a/events (level-triggered: it reconciles
#      the broker's pending_open threads, so a missed tick costs latency, never
#      correctness) and POSTs each pending open to Hermes's webhook adapter,
#      HMAC-signed. Redelivery is bounded solely by the thread leaving
#      pending_open (accept/reject/close) — see agent-auth docs/hermes-setup.md.
#
#   2. RECEIVER (Hermes): a webhook route `a2a-dispatch` on loopback:8644 that
#      spawns one worker conversation per open. The route `prompt` (below) is the
#      whole worker protocol; serve carries only raw thread facts as JSON.
#
# Session model: Hermes shares ONE agent-auth MCP subprocess across all
# conversations, so the worker mints its OWN broker session (create_session) and
# threads the returned id as `session_key` on every a2a/request_access call — that
# binds the thread to this conversation without a process-global that concurrent
# workers would clobber. One session can span multiple threads (e.g. downstream
# hermes→hermes opens). A redelivered duplicate is harmless: its a2a_accept finds
# the thread already claimed and the worker exits (step 2 below).
#
# Auth: serve signs its POST with X-Agent-Auth-Signature's HMAC bytes but under the
# `X-Hub-Signature-256` header (--sig-header), which is byte-identical to GitHub's
# scheme — so Hermes's built-in GitHub verifier authenticates it with the shared
# route secret. No Hermes patch, real HMAC (not just loopback trust).
#
# ── One-time bootstrap ────────────────────────────────────────────────────────
#   - Add to the sops env (nixos/hosts/recusant/secrets/hermes-homelab-recusant.env):
#       AGENT_AUTH_WEBHOOK_SECRET=<random 32+ char secret>   # shared: serve signs,
#                                                            #   Hermes route verifies
#       A2A_DELIVER_CHANNEL=1524682829999636571              # a2a observability channel
#   - Ensure the Hermes Discord bot can post to A2A_DELIVER_CHANNEL.
#   - Peers open threads with their own a2a `talk` grant to hermes-homelab-recusant;
#     with policy rules:[] every open surfaces to Discord for approval (deliberate).
#   - After rebuild, verify the agent-auth a2a tools are available inside a
#     webhook-spawned run (the run uses the configured mcp_servers). If a restricted
#     webhook toolset hides them, widen it via `hermes tools` for the webhook platform.
{
  config,
  inputs,
  pkgs,
  ...
}:
let
  instance = "hermes-homelab-recusant";
  stateDir = "/var/lib/${instance}";

  agentAuth = inputs.agent-auth.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # Dispatcher talks to the LOCAL broker (skip the nginx/TLS hop the system-wide
  # AGENT_AUTH_URL uses) and to Hermes's loopback webhook.
  brokerUrl = "http://127.0.0.1:${toString config.services.agent-auth.port}";
  webhookPort = 8644;
  onOpenUrl = "http://127.0.0.1:${toString webhookPort}/webhooks/a2a-dispatch";
  stateFile = "${stateDir}/.hermes/a2a-serve-state.json";

  # The worker protocol. {thread_id}/{peer}/{topic}/{payload} are Hermes webhook
  # template refs (dot-notation over serve's POST body), NOT Nix interpolation.
  workerPrompt = ''
    You are a Hermes worker serving ONE agent-to-agent (a2a) request routed through
    the agent-auth broker. You have the agent-auth MCP tools.

    Peer agent: {peer}
    a2a thread id: {thread_id}
    Topic: {topic}
    The peer's opening request (JSON): {payload}

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
in
{
  # ── Receiver: Hermes webhook adapter + a2a route (deep-merged into the instance) ──
  modules.apps.hermes-agents.instances.${instance}.settings.platforms.webhook = {
    enabled = true;
    extra = {
      host = "127.0.0.1"; # loopback: only the local dispatcher can reach it
      port = webhookPort;
      routes.a2a-dispatch = {
        # Shared HMAC secret (resolved from the sops .env at runtime; never in the
        # store). serve signs under X-Hub-Signature-256 → Hermes's GitHub verifier.
        secret = "\${AGENT_AUTH_WEBHOOK_SECRET}";
        prompt = workerPrompt;
        # Observability mirror only — the real result goes to the a2a thread.
        deliver = "discord";
        deliver_extra.chat_id = "\${A2A_DELIVER_CHANNEL}";
      };
    };
  };

  # A webhook-secret rotation should restart the dispatcher too (it signs with it).
  sops.secrets."${instance}/env".restartUnits = [ "${instance}-a2a-dispatcher.service" ];

  # ── Dispatcher: resident sessionless events loop → Hermes webhook ────────────
  systemd.services."${instance}-a2a-dispatcher" = {
    description = "a2a dispatcher for ${instance} (agent-auth serve → Hermes webhook)";
    # Best-effort ordering; serve retries on connection errors, so it tolerates the
    # broker or gateway not being up yet.
    after = [
      "network-online.target"
      "agent-auth.service"
      "${instance}.service"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      AGENT_AUTH_URL = brokerUrl;
      HOME = stateDir; # serve's default state path (unused; we pass --state) + tidy home
    };

    serviceConfig = {
      User = instance;
      Group = instance;
      # AGENT_AUTH_API_KEY (identifies hermes to the broker) + AGENT_AUTH_WEBHOOK_SECRET
      # (--hmac-env default) both live in the instance's sops env.
      EnvironmentFile = config.sops.secrets."${instance}/env".path;
      ExecStart = builtins.concatStringsSep " " [
        "${agentAuth}/bin/agent-auth a2a serve"
        "--on-open-url ${onOpenUrl}"
        "--sig-header X-Hub-Signature-256"
        "--state ${stateFile}"
      ];
      Restart = "always";
      RestartSec = 5;

      # Hardening: it only needs loopback HTTP and its state file.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ stateDir ];
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
    };
  };
}
