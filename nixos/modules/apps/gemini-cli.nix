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
      ../../../lib/features/agent-peers.nix
      ../../../lib/features/agent-gpu-command.nix
    ];

    config.app = {
      name = "gemini-cli";
      # Google retired Gemini CLI in favor of Antigravity CLI. Keep the app
      # identity stable so existing sandbox state and module options survive.
      packageName = "agy";
      package = pkgs.antigravity-cli;

      defaultBackend = "nixpak";

      # Empty on disk today, so just the config/creds dir on the backed-up tier.
      # Carve a cache tier if/when gemini starts writing one under ~/.gemini.
      storage = [
        {
          path = ".gemini";
          tier = "persist";
        }
      ];

      # $PWD comes from cwd.nix; the stash bind provides ~/.gemini. /tmp is a
      # PRIVATE tmpfs (not the shared host /tmp) so scratch files are per-app and
      # invisible to other sandboxes/the host; TMPDIR is pinned into it.
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
