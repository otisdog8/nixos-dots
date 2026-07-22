# Claude Code - AI-powered coding assistant

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
      ../../../lib/features/nix-store.nix
      ../../../lib/features/bin-sh.nix
    ];

    config.app = {
      name = "claude-code";
      packageName = "claude";
      # Track the fresher nixos-unstable-small channel so claude-code updates
      # land sooner than the main nixos-unstable pin (still binary-cached).
      package = pkgs.unstable-small.claude-code;

      defaultBackend = "nixpak";

      storage = [
        # Parent catches auth + real state (projects, history.jsonl, plans, tasks,
        # backups) and anything else claude writes under ~/.claude.
        {
          path = ".claude";
          tier = "persist";
        }
        {
          path = ".claude.json";
          tier = "persist";
          type = "file";
        }
        # Big non-regenerable-but-not-backup-worthy → /large (local snapshots only).
        {
          path = ".claude/security";
          tier = "large";
        } # ~282M
        {
          path = ".claude/file-history";
          tier = "large";
        } # ~19M edit-undo history
        {
          path = ".claude/plugins";
          tier = "large";
        } # ~8.8M, re-installable
        # Disposable → /cache.
        {
          path = ".claude/cache";
          tier = "cache";
        }
        {
          path = ".claude/paste-cache";
          tier = "cache";
        }
        {
          path = ".claude/shell-snapshots";
          tier = "cache";
        }
        {
          path = ".claude/jobs";
          tier = "cache";
        }
        {
          path = ".claude/daemon";
          tier = "cache";
        }
        {
          path = ".claude/telemetry";
          tier = "cache";
        }
        {
          path = ".claude/stats-cache.json";
          tier = "cache";
          type = "file";
        }
      ];

      # $PWD comes from cwd.nix; the stash binds provide ~/.claude and
      # ~/.claude.json. /tmp is a PRIVATE tmpfs (not the shared host /tmp): a
      # per-app scratch dir so nothing this agent writes to /tmp is visible to
      # other sandboxes or the host, and nothing on the host /tmp is visible to
      # it. TMPDIR is pinned so tools that honour it land inside that tmpfs.
      nixpakModules = [
        (
          { ... }:
          {
            bubblewrap.tmpfs = [ "/tmp" ];
            bubblewrap.env.TMPDIR = "/tmp";
          }
        )
      ];
    };
  }
)
