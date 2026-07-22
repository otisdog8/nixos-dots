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
      name = "gemini-cli";
      packageName = "gemini";
      package = pkgs.gemini-cli;

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
