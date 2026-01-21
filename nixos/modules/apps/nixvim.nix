let
  helper = import ../../../lib/apps.nix;
in
helper.mkApp (
  {
    config,
    lib,
    pkgs,
    inputs ? { },
    ...
  }:
  let
    nixvimInput = inputs.nixvim or config._module.args.inputs.nixvim;
    inherit (pkgs.stdenv.hostPlatform) system;
    nixvimPackage = nixvimInput.legacyPackages.${system}.makeNixvimWithModule {
      module = import ./nixvim;
    };
  in
  {
    imports = [
      ../../../lib/app-spec.nix
      ../../../lib/features/system-bin.nix
      ../../../lib/features/cwd.nix
      ../../../lib/features/network.nix
    ];

    config.app = {
      name = "nixvim";
      packageName = "nvim";
      package = nixvimPackage;

      persistence.user = {
        persist = [
          ".config/nvim"
          ".local/share/nvim"
        ];

        cache = [
          ".local/state/nvim"
        ];
      };

      nixpakModules = [
        (
          { lib, sloth, ... }:
          {
            dbus.enable = false;
            bubblewrap = {
              sockets.wayland = false;
              tmpfs = [ "/tmp" ];
              bind = {
                rw = [
                  (sloth.concat' (sloth.envOr "XDG_RUNTIME_DIR" "/") "/wayland-1")
                  (sloth.concat' (sloth.envOr "XDG_RUNTIME_DIR" "/") "/dune/")
                  # OpenCode state directories (required for ACP integration)
                  (sloth.concat' sloth.homeDir "/.local/state/opencode")
                  (sloth.concat' sloth.homeDir "/.local/share/opencode")
                  (sloth.concat' sloth.homeDir "/.config/opencode")
                  (sloth.concat' sloth.homeDir "/.opencode")
                  (sloth.concat' sloth.homeDir "/.cache/opencode")
                  (sloth.concat' sloth.homeDir "/.opam")
                  (sloth.concat' sloth.homeDir "/.cache/dune")
                  # Git repositories and operations
                  (sloth.concat' sloth.homeDir "/.config/git") # Git configuration directory
                  (sloth.concat' sloth.homeDir "/.ssh") # Git configuration directory
                ];
                ro = [
                  "/bin" # Required for nixd LSP to access nix store and evaluate nix expressions
                  "/nix" # Required for nixd LSP to access nix store and evaluate nix expressions
                  "/etc/nix" # Required for nixd LSP to access nix configuration
                  "/etc/static/nix" # Required for nixd LSP to access nix configuration
                  "/etc/passwd" # Required for nixd LSP to access nix configuration
                  "/etc/localtime" # Required for nixd LSP to access nix configuration
                  "/etc/zoneinfo" # Required for nixd LSP to access nix configuration
                ];
                lastArg = true;
              };
            };
          }
        )
      ];

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.nixvim.sandbox.enable = lib.mkDefault true;
        };
    };
  }
)
