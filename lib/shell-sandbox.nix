# Creates sandboxed shell wrappers using feature composition
{ config, lib, pkgs, ... }:

let
  # Helper to create a sandboxed shell app using features
  mkSandboxedShell = name: features: (import ./apps.nix).mkApp (
    { config, lib, pkgs, ... }: {
      imports = features;

      config.app = {
        name = "zsh-${name}";
        package = pkgs.zsh;
        packageName = "zsh";

        # Grant read-only access to zsh config
        nixpakModules = [
          ({ lib, sloth, ... }: {
            bubblewrap.bind.ro = [
              (sloth.concat' sloth.homeDir "/.zshrc")
              (sloth.concat' sloth.homeDir "/.config/zsh")
              "/etc/zsh"
            ];
          })
        ];
      };
    }
  );
in
{
  options.shellSandbox = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable sandboxed shell wrappers";
    };
  };

  config = lib.mkIf config.shellSandbox.enable {
    # Create sandboxed shell variants by composing features
    imports = [
      # Maximum isolation: no features
      (mkSandboxedShell "isolated" [])

      # Current directory only
      (mkSandboxedShell "cwd" [
        ./features/filesystem-cwd.nix
      ])

      # Current directory + network
      (mkSandboxedShell "cwd-net" [
        ./features/filesystem-cwd.nix
        ./features/network.nix
      ])

      # Full home directory
      (mkSandboxedShell "home" [
        ./features/filesystem-homedir.nix
      ])

      # Full home + network
      (mkSandboxedShell "home-net" [
        ./features/filesystem-homedir.nix
        ./features/network.nix
      ])
    ];
  };
}
