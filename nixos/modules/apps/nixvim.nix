let
  helper = import ../../../lib/apps.nix;
in
helper.mkApp (
  { config, lib, pkgs, inputs ? {}, ... }:
  let
    nixvimInput =
      if inputs ? nixvim then inputs.nixvim else config._module.args.inputs.nixvim;
    system = pkgs.stdenv.hostPlatform.system;
    nixvimPackage = nixvimInput.legacyPackages.${system}.makeNixvim {
        clipboard.register = "unnamedplus";
        colorscheme = "catppuccin";
        colorschemes.catppuccin.enable = true;
        globals.mapleader = " ";
        opts = {
          number = true;
          relativenumber = true;
          shiftwidth = 2;
          tabstop = 2;
        };
        plugins = {
          lualine.enable = true;
          telescope.enable = true;
          treesitter.enable = true;
        };
        dependencies = {
          ripgrep.enable = true;
          git.enable = true;
        };
    };
  in
  {
    imports = [ ../../../lib/app-spec.nix ];

    config.app = {
      name = "nixvim";
      packageName = "nvim";
      package = nixvimPackage;

      nixpakModules = [
        ({ lib, sloth, ... }: {
          bubblewrap = {
            bind.rw = [
              (sloth.env "PWD")
            ];
          };
        })
      ];

      customConfig = { config, lib, ... }: {
        modules.apps.nixvim.sandbox.enable = lib.mkDefault true;
        modules.apps.nixvim.sandbox.extraBinds = lib.mkDefault [ ];
        environment.systemPackages = [ config.modules.apps.nixvim.finalPackage ];
      };
    };
  }
)
