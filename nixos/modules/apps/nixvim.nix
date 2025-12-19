let
  helper = import ../../../lib/apps.nix;
in
helper.mkApp (
  { config, lib, pkgs, inputs ? {}, ... }:
  let
    nixvimInput =
      if inputs ? nixvim then inputs.nixvim else config._module.args.inputs.nixvim;
    system = pkgs.stdenv.hostPlatform.system;
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

      persistence.user.persist = [
        ".config/nvim"
        ".local/share/nvim"
      ];

      persistence.user.cache = [
        ".local/state/nvim"
      ];

      nixpakModules = [
        ({ lib, sloth, ... }: {
          dbus.enable = false;
          bubblewrap = {
            sockets.wayland = false;
            tmpfs = [ "/tmp" ];
            bind.rw = [
              (sloth.concat' (sloth.envOr "XDG_RUNTIME_DIR" "/") "/wayland-1")
            ];
						bind.ro = [
	          	"/nix"  # Required for nixd LSP to access nix store and evaluate nix expressions
          		"/etc/nix"  # Required for nixd LSP to access nix configuration
          		"/etc/static/nix"  # Required for nixd LSP to access nix configuration
					  ];
            bind.lastArg = true;
          };
        })
      ];

      customConfig = { config, lib, ... }: {
        modules.apps.nixvim.sandbox.enable = lib.mkDefault true;
      };
    };
	}
)
