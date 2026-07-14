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
    ];

    config.app = {
      name = "codex";
      packageName = "codex";
      # Track the fresher nixos-unstable-small channel so codex updates land
      # sooner than the main nixos-unstable pin (still binary-cached), matching
      # claude-code.
      package = pkgs.unstable-small.codex;

      defaultBackend = "nixpak";

      storage = [
        # Parent catches auth/config/state (goals/memories/state sqlite, skills,
        # sessions, models_cache.json) + anything codex writes we don't carve out.
        { path = ".codex"; tier = "persist"; }
        # 24M of churny SQLite logs — keep locally, out of backups.
        # NOTE: filename is versioned (logs_2 → may bump). If codex rotates to
        # logs_3.sqlite this carve goes stale (new logs land in the persist parent);
        # update the path on the next bump.
        {
          path = ".codex/logs_2.sqlite";
          tier = "large";
          type = "file";
        }
        { path = ".codex/plugins"; tier = "large"; } # ~27M, re-installable
        { path = ".codex/cache"; tier = "cache"; }
        { path = ".codex/.tmp"; tier = "cache"; }
      ];

      # $PWD comes from cwd.nix; the stash binds provide ~/.codex. Only the shared
      # host /tmp remains (preserved from the legacy config).
      nixpakModules = [
        (
          { ... }:
          {
            bubblewrap.bind.rw = [ "/tmp" ];
          }
        )
      ];
    };
  }
)
