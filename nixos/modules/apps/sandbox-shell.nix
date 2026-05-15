# Sandboxed zsh shell with a tmpfs $HOME and network access.
# Zsh init files (system + home-manager) are bound read-only so the shell
# behaves like the host shell on first launch, but any writes vanish on exit.

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
      ../../../lib/features/tmpfs-homedir.nix
      ../../../lib/features/network.nix
    ];

    config.app = {
      name = "sandbox-shell";
      packageName = "zsh";
      package = pkgs.zsh;

      nixpakModules = [
        (
          { sloth, ... }:
          {
            bubblewrap.bind.ro = [
              "/etc/zshrc"
              "/etc/zshenv"
              (sloth.concat' sloth.homeDir "/.zshrc")
              (sloth.concat' sloth.homeDir "/.zshenv")
            ];
          }
        )
      ];

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.sandbox-shell.sandbox.enable = lib.mkDefault true;
        };
    };
  }
)
