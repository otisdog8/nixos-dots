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
      name = "gemini-cli";
      packageName = "gemini";
      package = pkgs.gemini-cli;

      persistence.user.persist = [
        ".gemini"
      ];

      nixpakModules = [
        (
          { sloth, ... }:
          {
            bubblewrap.bind.rw = [
              (sloth.concat' sloth.homeDir "/.gemini")
              (sloth.env "PWD")
              "/tmp"
            ];
          }
        )
      ];

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.gemini-cli.sandbox.enable = lib.mkDefault true;
        };
    };
  }
)
