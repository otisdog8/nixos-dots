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
    ];

    config.app = {
      name = "claude-code";
      packageName = "claude";
      package = pkgs.claude-code;

      persistence.user.persist = [
        ".claude"
      ];

      persistence.user.persistFiles = [
        ".claude.json"
      ];

      nixpakModules = [
        (
          { sloth, ... }:
          {
            bubblewrap = {
              bind.rw = [
                (sloth.concat' sloth.homeDir "/.claude")
                (sloth.concat' sloth.homeDir "/.claude.json")
                (sloth.env "PWD")
              ];
            };
          }
        )
      ];

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.claude-code.sandbox.enable = lib.mkDefault true;
        };
    };
  }
)
