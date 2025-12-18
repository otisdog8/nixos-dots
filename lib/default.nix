{
  inputs,
  outputs,
  stateVersion,
  ...
}:
let
  isLaptopOuter = hostname: hostname == "constitution";
  isDesktopOuter = hostname: builtins.elem hostname [ "galaxy" "excelsior" ];
  isServerOuter = hostname: builtins.elem hostname [ "arquitens" "recusant" "munificent" "carrack" ];
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
        ../nixos
      ];
    };
}
