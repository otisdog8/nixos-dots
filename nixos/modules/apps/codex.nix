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
    ];

    config.app = {
      name = "codex";
      packageName = "codex";
      package = pkgs.codex;

      persistence.user.persist = [
        ".codex"
        ".config/codex"
      ];

      nixpakModules = [
        (
          { sloth, ... }:
          {
            bubblewrap.bind.rw = [
              (sloth.env "PWD")
              "/tmp"
            ];
          }
        )
      ];

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.codex.sandbox.enable = lib.mkDefault true;
        };
    };
  }
)
