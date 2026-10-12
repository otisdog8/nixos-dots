# Codex - OpenAI coding agent

(import ../../../lib/apps.nix).mkApp (
  {
    config,
    lib,
    pkgs,
    ...
  }:
  {
    imports = [
      ../../../lib/app-spec.nix
      ../../../lib/features/xdg.nix
      ../../../lib/features/network.nix
      ../../../lib/features/system-bin.nix
      ../../../lib/features/cwd.nix
      ../../../lib/features/git.nix
      ../../../lib/features/bin-sh.nix
      ../../../lib/features/agent-peers.nix
      ../../../lib/features/agent-gpu-command.nix
    ];

    # $PWD comes from cwd.nix; the stash binds provide ~/.codex.
    config.app = {
      name = "codex";
      packageName = "codex";
      # Track the fresher nixos-unstable-small channel so codex updates land
      # sooner than the main nixos-unstable pin (still binary-cached), matching
      # claude-code.
      package = pkgs.unstable-small.codex;

      defaultBackend = "nixpak";

      # As claude-code: plain `codex` runs in its own sandbox, `codex-agents`
      # in the shared agents sandbox; sessions share ~/.codex.
      groupCommand = "codex-agents";
      multiInstance = true;

      storage = [
        # Parent catches auth/config/state (goals/memories/state sqlite, skills,
        # sessions, models_cache.json) + anything codex writes we don't carve out.
        {
          path = ".codex";
          tier = "persist";
        }
        # .codex/logs_*.sqlite is NOT carved out: a single-file carve would move only
        # the main db (SQLite puts -wal/-shm beside it, in the persist parent), and
        # a file bind breaks SQLite's rename-based recovery.
        {
          path = ".codex/plugins";
          tier = "large";
        } # ~27M, re-installable
        {
          path = ".codex/cache";
          tier = "cache";
        }
        {
          path = ".codex/.tmp";
          tier = "cache";
        }
      ];
    };
  }
)
