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

      # Plain `claude` runs in its own sandbox; `claude-agents` runs it in the
      # shared agents sandbox (modules/system/sandbox-agents.nix), whose
      # projects and shared paths the own sandbox gets too.
      groupCommand = "claude-agents";

      # `claude-nesbox`: the same sandbox plus what the virtio-nvgpu GPU/VM tests
      # need. Opt-in per session; plain `claude` is unchanged. Device binds are
      # bind-try, so nodes absent on a host are skipped. /dev/nvidia-uvm-tools is
      # left out on purpose (the backend refuses it).
      # SECURITY: this session is effectively as powerful as the desktop itself:
      #   - nvidia.ko, /dev/kvm and all of /sys are reachable;
      #   - the live Hyprland Wayland socket (raw, NOT a security-context socket —
      #     that one hides wp_drm_lease_device_v1, which the lease tests need)
      #     exposes screencopy, virtual keyboard/pointer, data-control, layer-shell;
      #   - $XDG_RUNTIME_DIR/hypr (hyprctl) allows `dispatch exec` — running any
      #     command on the host outside the sandbox — and rewriting live config.
      # Use it only for those test sessions.
      variantCommands.claude-nesbox.nixpakModules = [
        (
          { sloth, ... }:
          {
            # The live session's Wayland socket at the same path inside, and
            # Hyprland's IPC sockets for hyprctl.
            bubblewrap.bind.rw = [
              (sloth.concat [
                sloth.runtimeDir
                "/"
                (sloth.envOr "WAYLAND_DISPLAY" "wayland-1")
              ])
              (sloth.concat' sloth.runtimeDir "/hypr")
            ];
            # envOr, not env: nixpak aborts the launch on an unset referenced var.
            bubblewrap.env = {
              WAYLAND_DISPLAY = sloth.envOr "WAYLAND_DISPLAY" "wayland-1";
              HYPRLAND_INSTANCE_SIGNATURE = sloth.envOr "HYPRLAND_INSTANCE_SIGNATURE" "";
            };
          }
        )
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
