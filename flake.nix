{
  description = "A template that shows all standard flake outputs";

  # Inputs
  # https://nixos.org/manual/nix/unstable/command-ref/new-cli/nix3-flake.html#flake-inputs

  # Work-in-progress: refer to parent/sibling flakes in the same repository
  # inputs.c-hello.url = "path:../c-hello";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable-small";
    nix-bwrapper.url = "github:Naxdy/nix-bwrapper";
    nixpak = {
      url = "github:otisdog8/nixpak/sandbox-xdg-runtime-dir";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    xdg-desktop-portal-src = {
      url = "github:otisdog8/xdg-desktop-portal/fallback-improvements-120";
      flake = false;
    };
    nixpkgs-older.url = "github:NixOS/nixpkgs?rev=3e042434c17eff8ed5528faa4c4503facc2bdf6c";
    nixpkgs-otisdog8.url = "github:otisdog8/nixpkgs/marvin";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";
    impermanence = {
      url = "github:nix-community/impermanence";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    hyprland = {
      url = "github:hyprwm/Hyprland";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixvim = {
      url = "github:nix-community/nixvim";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    Hyprspace = {
      url = "github:KZDKM/Hyprspace";

      # Hyprspace uses latest Hyprland. We declare this to keep them in sync.
      inputs.hyprland.follows = "hyprland";
    };
    hyprsplit = {
      url = "github:shezdy/hyprsplit/main";
      inputs.hyprland.follows = "hyprland";
    };
    rose-pine-hyprcursor = {
      url = "github:ndom91/rose-pine-hyprcursor";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    wezterm-flake.url = "github:wez/wezterm?dir=nix&rev=4506a7648e2ebef266225c1acdcd79967a4fc73b";
    wezterm-flake.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpak,
      nixos-hardware,
      chaotic,
      impermanence,
      lanzaboote,
      home-manager,
      zen-browser,
      hyprland,
      hyprsplit,
      Hyprspace,
      wezterm-flake,
      ...
    }@inputs:

    let
      inherit (self) outputs;
      stateVersion = "24.05";
      helper = import ./lib { inherit inputs outputs stateVersion; };
    in
    {
      overlays = import ./overlays { inherit inputs; };

      homeConfigurations = {
        "jrt@constitution" = helper.mkHome {
          hostname = "constitution";
          username = "jrt";
        };
        "jrt@matthew" = helper.mkHome {
          hostname = "matthew";
          username = "jrt";
        };
      };
      
      nixosConfigurations = {
        constitution = helper.mkNixos {
          hostname = "constitution";
          stateVersion = "24.05";
        };
        excelsior = helper.mkNixos {
          hostname = "excelsior";
          stateVersion = "24.05";
        };
        recusant = helper.mkNixos {
          hostname = "recusant";
          stateVersion = "24.05";
        };
        munificent = helper.mkNixos {
          hostname = "munificent";
          stateVersion = "24.05";
        };
        arquitens = helper.mkNixos {
          hostname = "arquitens";
          stateVersion = "24.05";
        };
        carrack = helper.mkNixos {
          hostname = "carrack";
          stateVersion = "24.05";
        };
        galaxy = helper.mkNixos {
          hostname = "galaxy";
          stateVersion = "25.05";
        };
      };

      devShells.x86_64-linux.default =
        let
          pkgs = import nixpkgs { system = "x86_64-linux"; };
        in
        pkgs.mkShell {
          packages = with pkgs; [
            statix
            nixd
            markdownlint-cli
            nixfmt-rfc-style
          ];
        };

    };
}
