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

      # v2 nixpak backend (replaces the legacy sandbox.enable path). location = "home"
      # for every entry: nvim is a same-uid dev editor (it edits $PWD as jrt), so a
      # hidden stash buys ~nothing, and home keeps its state at the normal ~ paths —
      # zero data movement on conversion, host-visible, and no risk of shadowing any
      # home-manager-managed ~/.config/nvim.
      defaultBackend = "nixpak";
      storage = [
        {
          path = ".config/nvim";
          tier = "persist";
          location = "home";
        }
        {
          path = ".local/share/nvim";
          tier = "persist";
          location = "home";
        }
        {
          path = ".local/state/nvim";
          tier = "cache";
          location = "home";
        }
      ];

      nixpakModules = [
        (
          { lib, sloth, ... }:
          {
            dbus.enable = false;
            bubblewrap = {
              dieWithParent = true;
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
    };
  }
)
