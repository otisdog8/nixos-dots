# Sandboxed zsh shell with a tmpfs $HOME and network access.
# Zsh init files (system + home-manager) are bound read-only so the shell
# behaves like the host shell on first launch, but any writes vanish on exit.
# Exposed as `sandbox-zsh` to avoid colliding with the host login shell.

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
      ../../../lib/features/cwd.nix
      ../../../lib/features/network.nix
      ../../../lib/features/system-bin.nix
    ];

    config.app = {
      name = "sandbox-shell";
      packageName = "sandbox-zsh";
      # zsh resolves its module/function paths from compile-time absolute
      # store paths, so a renamed symlink to bin/zsh is sufficient.
      package = pkgs.runCommand "sandbox-zsh-${pkgs.zsh.version}" { } ''
        mkdir -p $out/bin
        ln -s ${pkgs.zsh}/bin/zsh $out/bin/sandbox-zsh
      '';

      nixpakModules = [
        (
          { sloth, ... }:
          {
            bubblewrap.bind.ro = [
              "/etc/zshrc"
              "/etc/zshenv"
              "/etc/zinputrc"
              "/etc/profiles/per-user/jrt/bin"
              "/usr/bin/env"
              (sloth.concat' sloth.homeDir "/.zshrc")
              (sloth.concat' sloth.homeDir "/.zshenv")
              (sloth.concat' sloth.homeDir "/.zsh")
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
