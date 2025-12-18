# Claude Code - AI-powered coding assistant

(import ../../../lib/apps.nix).mkApp (
{ config, lib, pkgs, ... }: {
  imports = [
    ../../../lib/app-spec.nix
    ../../../lib/features/xdg.nix
    ../../../lib/features/network.nix
    ../../../lib/features/system-bin.nix
  ];

  config.app = {
    name = "opencode";
    packageName = "opencode";
    package = pkgs.opencode;

    persistence.user.persist = [
      ".local/state/opencode"
      ".local/share/opencode"
      ".config/opencode"
      ".opencode"
    ];

    persistence.user.cache = [
      ".cache/opencode"
    ];

    nixpakModules = [
      ({ sloth, ... }: {
        bubblewrap.bind.rw = [
          (sloth.concat' sloth.homeDir "/.opencode")
          (sloth.concat' sloth.homeDir "/.config/opencode")
          (sloth.concat' sloth.homeDir "/.local/share/opencode")
          (sloth.concat' sloth.homeDir "/.local/state/opencode")
          (sloth.concat' sloth.homeDir "/.cache/opencode")
          (sloth.env "PWD")
        ];
      })
    ];

    customConfig = { config, lib, ... }: {
      modules.apps.opencode.sandbox.enable = lib.mkDefault true;
    };
  };
}
)
