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
      module = {
        imports = [ ./nixvim ];
        # This input intentionally follows the system nixpkgs. Declaring the
        # source makes that choice explicit to Nixvim's nixpkgs module.
        nixpkgs.source = inputs.nixpkgs;
      };
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

      # location = "home" for every entry: nvim is a same-uid dev editor (it edits
      # $PWD as jrt), so a hidden stash buys ~nothing, and home keeps its state at
      # the normal ~ paths — host-visible, and no risk of shadowing any
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
              bind = {
                # No Wayland socket: nvim runs in a terminal and has no window of
                # its own. The raw compositor socket (no security context) gave
                # code in here a virtual keyboard, screencopy and the clipboard
                # of the whole session. The clipboard goes over OSC 52 through
                # the terminal instead (nixvim/core.nix).
                rw = [
                  (sloth.concat' (sloth.envOr "XDG_RUNTIME_DIR" "/") "/dune/")
                  # OpenCode state directories (required for ACP integration)
                  (sloth.concat' sloth.homeDir "/.local/state/opencode")
                  (sloth.concat' sloth.homeDir "/.local/share/opencode")
                  (sloth.concat' sloth.homeDir "/.config/opencode")
                  (sloth.concat' sloth.homeDir "/.opencode")
                  (sloth.concat' sloth.homeDir "/.cache/opencode")
                  (sloth.concat' sloth.homeDir "/.opam")
                  (sloth.concat' sloth.homeDir "/.cache/dune")
                  # NOT ~/.ssh — private keys must never enter the sandbox.
                  # Git-over-SSH goes through ssh-agent-git (customConfig below),
                  # bound where the agent's socket would be: it signs only for
                  # user "git" logins and git commit signatures. The plain agent
                  # socket let code in here ssh to this host's sshd as jrt.
                  [
                    (sloth.concat' (sloth.envOr "XDG_RUNTIME_DIR" "/") "/ssh-agent-git")
                    (sloth.concat' (sloth.envOr "XDG_RUNTIME_DIR" "/") "/ssh-agent")
                  ]
                ];
                ro = [
                  # Git config (identity/signing). Read-only: host git reads it on
                  # every run, so a writable one is code execution outside the
                  # sandbox (core.fsmonitor, core.pager, ...).
                  (sloth.concat' sloth.homeDir "/.config/git")
                  "/bin" # Required for nixd LSP to access nix store and evaluate nix expressions
                  "/nix" # Required for nixd LSP to access nix store and evaluate nix expressions
                  "/etc/nix" # Required for nixd LSP to access nix configuration
                  "/etc/static/nix" # Required for nixd LSP to access nix configuration
                  "/etc/passwd" # Required for nixd LSP to access nix configuration
                  "/etc/localtime" # Required for nixd LSP to access nix configuration
                  "/etc/zoneinfo" # Required for nixd LSP to access nix configuration
                  # Host verification only (public data): known_hosts + ssh config.
                  # No private keys — those stay with the agent.
                  (sloth.concat' sloth.homeDir "/.ssh/known_hosts")
                  (sloth.concat' sloth.homeDir "/.ssh/config")
                ];
                lastArg = true;
              };
            };
          }
        )
      ];

      # The filtered ssh-agent socket bound above (lib/ssh-agent-git.py), one
      # process per connection.
      customConfig =
        { config, pkgs, ... }:
        let
          filter = pkgs.writeScript "ssh-agent-git" (
            "#!${pkgs.python3}/bin/python3 -IS\n" + builtins.readFile ../../../lib/ssh-agent-git.py
          );
        in
        {
          systemd.user.sockets.ssh-agent-git = {
            description = "Filtered ssh-agent for sandboxed git (nixvim)";
            wantedBy = [ "sockets.target" ];
            listenStreams = [ "%t/ssh-agent-git" ];
            socketConfig = {
              Accept = true;
              SocketMode = "0600";
              MaxConnections = 16;
            };
          };
          systemd.user.services."ssh-agent-git@" = {
            description = "Filtered ssh-agent connection";
            serviceConfig = {
              ExecStart = "${filter} %t/ssh-agent";
              StandardInput = "socket";
              StandardOutput = "journal";
              StandardError = "journal";
            };
          };
        };
    };
  }
)
