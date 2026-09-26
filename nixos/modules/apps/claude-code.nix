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
      ../../../lib/features/agent-peers.nix
      ../../../lib/features/agent-gpu-command.nix
    ];

    # $PWD comes from cwd.nix; the stash binds provide ~/.claude and ~/.claude.json.
    config.app = {
      name = "claude-code";
      packageName = "claude";
      # Track the fresher nixos-unstable-small channel so claude-code updates
      # land sooner than the main nixos-unstable pin (still binary-cached).
      package = pkgs.unstable-small.claude-code;

      defaultBackend = "nixpak";

      # `claude-nesbox`: the same sandbox plus the hardware the nesbox GPU/VM tests
      # need. Opt-in per session; plain `claude` is unchanged. SECURITY: anything in
      # the session can reach nvidia.ko and /dev/kvm and read all of /sys. Still no
      # Wayland socket (a live compositor socket allows input injection and
      # screencopy); run a separate compositor inside instead. Device binds are
      # bind-try, so nodes absent on a host are skipped. /dev/nvidia-uvm-tools is
      # left out on purpose (the backend refuses it).
      variantCommands.claude-nesbox.nixpakModules = [
        (_: {
          bubblewrap.bind.dev = [
            "/dev/kvm"
            "/dev/udmabuf"
            "/dev/nvidiactl"
            "/dev/nvidia0"
            "/dev/nvidia-uvm"
            "/dev/nvidia-modeset"
            "/dev/nvidia-caps"
            "/dev/dri"
          ];
          # Device lookup, libdrm and nvidia-smi.
          bubblewrap.bind.ro = [
            "/sys"
            "/run/opengl-driver"
          ];
        })
      ];

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
    };
  }
)
