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

    # $PWD comes from cwd.nix; the stash bind provides ~/.gemini.
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
    };
  }
)
