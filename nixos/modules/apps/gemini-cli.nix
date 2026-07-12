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
        { path = ".gemini"; tier = "persist"; }
      ];

      # $PWD comes from cwd.nix; the stash bind provides ~/.gemini. Only the
      # shared host /tmp remains (preserved from the legacy config).
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
