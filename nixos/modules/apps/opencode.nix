# opencode — AI coding agent (interactive TUI) — v2 nixpak backend.
#
# Interactive CLIs stay on the in-session nixpak backend: a system-service stash
# has no PTY, and the app's terminal is essential. So opencode runs as jrt in the
# session (sandboxed, creds NOT hidden from other jrt processes) but uses the
# unified /persist/sandbox layout, so config/state land on the backed-up tier and
# the cache on the disposable tier. cwd.nix binds $PWD for project work.

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
    ];

    config.app = {
      name = "opencode";
      packageName = "opencode";
      package = pkgs.opencode;

      defaultBackend = "nixpak";

      storage = [
        {
          path = ".local/state/opencode";
          tier = "persist";
        }
        {
          path = ".local/share/opencode";
          tier = "persist";
        }
        {
          path = ".config/opencode";
          tier = "persist";
        }
        {
          path = ".opencode";
          tier = "persist";
        }
        {
          path = ".cache/opencode";
          tier = "cache";
        }
      ];
    };
  }
)
