# hindsight — shared long-term memory for the Hermes agent instances
# (https://github.com/vectorize-io/hindsight). One service, many agents:
# isolation between agents is per-bank (HINDSIGHT_BANK_ID on the Hermes side),
# so a future chat-agent is a new bank, not a new deployment.
#
# Built from source with uv2nix (reusing hermes-agent's pinned uv2nix inputs).
# We run hindsight-api-slim — the API-provider-only build. The fat
# `hindsight-api` package exists solely to pull sentence-transformers/torch
# for on-box embeddings/reranking, which we don't want: LLM, embeddings, and
# reranking are all remote here.
#
# The extraction LLM rides the ChatGPT subscription via the native
# `openai-codex` provider, reading rotating OAuth tokens from
# ~/.codex/auth.json under this service's persisted home. That path is the
# Responses API and it works.
#
# Embeddings and reranking do NOT ride Codex. The ChatGPT subscription carries
# no platform quota for OpenAI's /v1/embeddings, so a codex-OAuth bearer to
# that endpoint authenticates but 429s with `insufficient_quota` (hindsight's
# CodexOAuthEmbeddings assumed the subscription token could bill embeddings —
# it can't). Both therefore go to OpenRouter instead: embeddings via its
# OpenAI-compatible /embeddings, reranking via its Cohere-format /rerank,
# behind one shared HINDSIGHT_API_OPENROUTER_API_KEY (see the sops env). RRF
# fusion of semantic/BM25/graph/temporal recall still runs first; the reranker
# just adds a neural pass on top of it.
#
# ── One-time bootstrap ────────────────────────────────────────────────────────
#   1. Fill the env secrets (tenant key gates the whole API; DB password must
#      be %-free and URL-safe — mint both with `openssl rand -hex 24`):
#        sops nixos/hosts/recusant/secrets/hindsight.env
#          HINDSIGHT_API_TENANT_API_KEY=...
#          HINDSIGHT_DB_PASSWORD=<hex>          # consumed by hindsight-db-init
#          HINDSIGHT_API_DATABASE_URL=postgresql://hindsight:<same hex>@127.0.0.1:5432/hindsight
#          HINDSIGHT_API_OPENROUTER_API_KEY=... # embeddings + reranker (one
#                                               # key serves both; reuse the
#                                               # hermes instance's OpenRouter key)
#      (TCP + password, NOT the unix socket: upstream's alembic wrapper chokes
#      on the %2F a socket path picks up in URL normalization — configparser
#      interpolation. And NOT pg_hba `trust`: any local user could then
#      impersonate the DB role and bypass the tenant key.)
#   2. Codex OAuth (writes ~/.codex/auth.json, then auto-refreshes forever):
#        sudo -u hindsight env HOME=/var/lib/hindsight codex auth login
#      (headless: it prints the device-code URL; finish in any browser)
#   3. Rebuild; check `journalctl -u hindsight-api` for clean migrations.
#   4. If a long outage kills the refresh token: repeat step 2.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  inherit (inputs.hermes-agent.inputs) uv2nix pyproject-nix pyproject-build-systems;

  workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = inputs.hindsight; };
  overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };
  pythonSet =
    (pkgs.callPackage pyproject-nix.build.packages { python = pkgs.python312; }).overrideScope
      (
        lib.composeManyExtensions [
          pyproject-build-systems.overlays.default
          overlay
        ]
      );
  # Slim package, no extras: API-provider-only closure (no torch).
  hindsightEnv = pythonSet.mkVirtualEnv "hindsight-api-slim-env" { hindsight-api-slim = [ ]; };

  stateDir = "/var/lib/hindsight";
  port = 8888; # localhost-only; agents on this box reach it via HINDSIGHT_API_URL
in
{
  # ── Secrets ────────────────────────────────────────────────────────────────
  sops.secrets."hindsight/env" = {
    format = "dotenv";
    sopsFile = ./secrets/hindsight.env;
    key = "";
    restartUnits = [
      "hindsight-db-init.service" # re-applies the role password on rotation
      "hindsight-api.service"
    ];
  };

  # ── PostgreSQL + pgvector ──────────────────────────────────────────────────
  services.postgresql = {
    enable = true;
    ensureDatabases = [ "hindsight" ];
    ensureUsers = [
      {
        name = "hindsight";
        ensureDBOwnership = true;
      }
    ];
    extensions = ps: [ ps.pgvector ];
  };

  # Two things the service user can't do for itself: pgvector needs a
  # superuser to CREATE EXTENSION, and the hindsight role needs a password
  # for TCP auth (see the bootstrap header for why not socket/trust). The
  # password comes from the sops env file — systemd (pid 1) reads
  # EnvironmentFile before dropping to User=postgres, so the unit sees it
  # without the postgres user needing read access to the secret.
  systemd.services.hindsight-db-init = {
    description = "Provision pgvector extension + role password for hindsight";
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      RemainAfterExit = true;
      EnvironmentFile = config.sops.secrets."hindsight/env".path;
    };
    script = ''
      psql=${config.services.postgresql.package}/bin/psql
      $psql -d hindsight -c 'CREATE EXTENSION IF NOT EXISTS vector;'
      # :'var' interpolation (SQL-literal quoting) only applies to stdin
      # input — psql -c deliberately skips it — so feed the statement in.
      echo "ALTER ROLE hindsight WITH PASSWORD :'pw';" \
        | $psql -v ON_ERROR_STOP=1 -v pw="$HINDSIGHT_DB_PASSWORD"
    '';
  };

  # ── Service user ───────────────────────────────────────────────────────────
  # Real shell + persisted home: the codex device-code login (bootstrap step 2)
  # runs as this user, and ~/.codex/auth.json rotates under it afterwards.
  users.groups.hindsight = { };
  users.users.hindsight = {
    isSystemUser = true;
    group = "hindsight";
    home = stateDir;
    createHome = true;
    shell = pkgs.bashInteractive;
  };

  # ── The API ────────────────────────────────────────────────────────────────
  systemd.services.hindsight-api = {
    description = "Hindsight agent memory API";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "postgresql.service"
      "hindsight-db-init.service"
    ];
    wants = [ "network-online.target" ];
    requires = [
      "postgresql.service"
      "hindsight-db-init.service"
    ];

    environment = {
      HOME = stateDir; # → ~/.codex/auth.json
      HINDSIGHT_API_HOST = "127.0.0.1";
      HINDSIGHT_API_PORT = toString port;
      # HINDSIGHT_API_DATABASE_URL deliberately NOT set here: it embeds the
      # role password, so it lives in the sops env file (bootstrap step 1).
      #
      # Extraction LLM on the ChatGPT subscription via Codex OAuth (works).
      HINDSIGHT_API_LLM_PROVIDER = "openai-codex";

      # Embeddings + reranking on OpenRouter (Codex can't bill either — see
      # header). Models are pinned rather than left to upstream's defaults:
      # the vector dimension is a function of the embeddings model, so an input
      # bump that shifted the default would silently break similarity against
      # already-stored vectors. Both endpoints/base-URLs are hardcoded in
      # hindsight's provider factory, so only the model IDs need setting.
      HINDSIGHT_API_EMBEDDINGS_PROVIDER = "openrouter";
      HINDSIGHT_API_EMBEDDINGS_OPENROUTER_MODEL = "perplexity/pplx-embed-v1-0.6b";
      HINDSIGHT_API_RERANKER_PROVIDER = "openrouter";
      HINDSIGHT_API_RERANKER_OPENROUTER_MODEL = "cohere/rerank-v3.5";
    };

    serviceConfig = {
      User = "hindsight";
      Group = "hindsight";
      ExecStart = "${hindsightEnv}/bin/hindsight-api";
      # Tenant API key (mandatory: without it, anything that can reach the
      # port can read every agent's memory).
      EnvironmentFile = config.sops.secrets."hindsight/env".path;
      Restart = "always";
      RestartSec = 5;
      WorkingDirectory = stateDir;

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

  # codex CLI available for the bootstrap login (and manual re-auth).
  environment.systemPackages = [ pkgs.codex ];

  # ── Impermanence ───────────────────────────────────────────────────────────
  # Postgres holds the memories; stateDir holds the codex OAuth store.
  environment.persistence."/persist".directories = [
    {
      directory = stateDir;
      user = "hindsight";
      group = "hindsight";
      mode = "0750";
    }
    {
      directory = "/var/lib/postgresql";
      user = "postgres";
      group = "postgres";
      mode = "0750";
    }
  ];
}
