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
# Every LLM-ish call rides the ChatGPT subscription via the native
# `openai-codex` provider (extraction LLM *and* embeddings), reading rotating
# OAuth tokens from ~/.codex/auth.json under this service's persisted home.
# Reranker is `rrf`: recall still fuses semantic/BM25/graph/temporal results
# with RRF, we just skip the extra rerank pass instead of paying for it.
# If subscription quota (weekly caps!) or OpenAI tolerance of the codex-auth
# pattern becomes a problem, flip the three *_PROVIDER vars to `openrouter`
# and add HINDSIGHT_API_OPENROUTER_API_KEY to the sops env.
#
# ── One-time bootstrap ────────────────────────────────────────────────────────
#   1. Fill the env secrets (tenant key gates the whole API — mint something
#      long, e.g. `openssl rand -base64 33`):
#        sops nixos/hosts/recusant/secrets/hindsight.env
#          HINDSIGHT_API_TENANT_API_KEY=...
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
    restartUnits = [ "hindsight-api.service" ];
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

  # Hindsight's migrations run CREATE EXTENSION IF NOT EXISTS, but only a
  # superuser may create pgvector — pre-create it so the service user can't
  # get stuck.
  systemd.services.hindsight-db-init = {
    description = "Create pgvector extension for hindsight";
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      RemainAfterExit = true;
    };
    script = ''
      ${config.services.postgresql.package}/bin/psql -d hindsight \
        -c 'CREATE EXTENSION IF NOT EXISTS vector;'
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
      # Peer auth over the local socket — no password to manage.
      HINDSIGHT_API_DATABASE_URL = "postgresql://hindsight@/hindsight?host=/run/postgresql";
      # Subscription-backed brains (see header for the openrouter fallback).
      HINDSIGHT_API_LLM_PROVIDER = "openai-codex";
      HINDSIGHT_API_EMBEDDINGS_PROVIDER = "openai-codex";
      # RRF passthrough: retrieval fusion only, neural reranking disabled —
      # no local model, no API calls. ("none" is not an accepted value.)
      HINDSIGHT_API_RERANKER_PROVIDER = "rrf";
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
