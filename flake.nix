{
  description = "A template that shows all standard flake outputs";

  # Inputs
  # https://nixos.org/manual/nix/unstable/command-ref/new-cli/nix3-flake.html#flake-inputs

  # Work-in-progress: refer to parent/sibling flakes in the same repository
  # inputs.c-hello.url = "path:../c-hello";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-otisdog8.url = "github:otisdog8/nixpkgs";
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
      url = "github:nix-community/lanzaboote/v0.4.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zen-browser.url = "github:0xc000022070/zen-browser-flake";
    hyprland.url = "github:hyprwm/Hyprland?submodules=1";
    Hyprspace = {
      url = "github:KZDKM/Hyprspace";

      # Hyprspace uses latest Hyprland. We declare this to keep them in sync.
      inputs.hyprland.follows = "hyprland";
    };
    hyprsplit = {
      url = "github:otisdog8/hyprsplit/main";
      inputs.hyprland.follows = "hyprland";
    };
    rose-pine-hyprcursor.url = "github:ndom91/rose-pine-hyprcursor";
    wezterm-flake.url = "github:wez/wezterm/main?dir=nix";
    wezterm-flake.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nixos-hardware, chaotic, impermanence, lanzaboote, home-manager, zen-browser, hyprland, hyprsplit, Hyprspace, wezterm-flake, ... }@inputs:
    let
      inherit (self) outputs;
      stateVersion = "24.05";
      helper = import ./lib { inherit inputs outputs stateVersion; };
      in {
    overlays = import ./overlays {inherit inputs;};
    homeConfigurations = {
      "jrt@constitution" = helper.mkHome {
        hostname = "constitution";
        username = "jrt";
      };
    };
    nixosConfigurations.constitution = helper.mkNixos {
      hostname = "constitution";
      stateVersion = "24.05";
    };
    nixosConfigurations.excelsior = helper.mkNixos {
      hostname = "excelsior";
      stateVersion = "24.05";
    };
    nixosConfigurations.recusant = helper.mkNixos {
      hostname = "recusant";
      stateVersion = "24.05";
    };
    nixosConfigurations.fantail = helper.mkNixos {
      hostname = "fantail";
      stateVersion = "24.05";
    };
    nixosConfigurations.munificent = helper.mkNixos {
      hostname = "munificent";
      stateVersion = "24.05";
    };
    nixosConfigurations.arquitens = helper.mkNixos {
      hostname = "arquitens";
      stateVersion = "24.05";
    };
    nixosConfigurations.carrack = helper.mkNixos {
      hostname = "carrack";
      stateVersion = "24.05";
    };

  };
}
