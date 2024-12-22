{
  inputs,
  outputs,
  stateVersion,
  ...
}:
let
  isLaptopOuter = hostname: hostname == "constitution";
  isDesktopOuter = hostname: false;
  isServerOuter = hostname: false;
  defaultUsername = "jrt";
in
{
  # Helper function for generating home-manager configs
  mkHome =
    {
      hostname,
      username ? defaultUsername,
      platform ? "x86_64-linux",
    }:
    let
      isLaptop = isLaptopOuter hostname;
      isDesktop = isDesktopOuter hostname;
      isServer = isServerOuter hostname;
    in
    inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = inputs.nixpkgs.legacyPackages.${platform};
      extraSpecialArgs = {
        inherit
          inputs
          outputs
          hostname
          platform
          username
          stateVersion
          isLaptop
          isDesktop
          isServer
          ;
      };
      modules = [ ../home-manager ];
    };

  # Helper function for generating NixOS configs
  mkNixos =
    {
      hostname,
      stateVersion,
      username ? defaultUsername,
      platform ? "x86_64-linux",
    }:
    let
      isLaptop = isLaptopOuter hostname;
      isDesktop = isDesktopOuter hostname;
      isServer = isServerOuter hostname;
    in
    inputs.nixpkgs.lib.nixosSystem {
      specialArgs = {
        inherit
          inputs
          outputs
          hostname
          platform
          username
          stateVersion
          isLaptop
          isDesktop
          isServer
          ;
      };
      # If the hostname starts with "iso-", generate an ISO image
      modules = [
          ({
              nixpkgs.system = "x86_64-linux";
              inputs.nixpkgs.pkgs = import inputs.nixpkgs {
                system = "x86_64-linux";
                overlays = [
                  inputs.k0s.overlays.default
                ];
              };
          })
        ../nixos
      ];
    };

  # TBD: left blank
  mkDarwin =
    {
      desktop ? "aqua",
      hostname,
      username ? defaultUsername,
      platform ? "aarch64-darwin",
    }:
    let
      isLaptop = isLaptopOuter hostname;
      isDesktop = isDesktopOuter hostname;
      isServer = isServerOuter hostname;
    in
    inputs.nix-darwin.lib.darwinSystem {
      specialArgs = {
        inherit
          inputs
          outputs
          desktop
          hostname
          platform
          username
          stateVersion
          ;
      };
      modules = [ ../darwin ];
    };

  forAllSystems = inputs.nixpkgs.lib.genAttrs [
    "aarch64-linux"
    "x86_64-linux"
    "aarch64-darwin"
    "x86_64-darwin"
  ];
}
