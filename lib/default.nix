{
  inputs,
  outputs,
  stateVersion,
  ...
}:
let
  isLaptopOuter = hostname: hostname == "constitution";
  isDesktopOuter =
    hostname:
    builtins.elem hostname [
      "galaxy"
      "excelsior"
    ];
  isServerOuter =
    hostname:
    builtins.elem hostname [
      "arquitens"
      "arquitens-hv"
      "recusant"
      "munificent"
      "carrack"
    ];
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
  # hostDir: the nixos/hosts/ directory, when it isn't named after the host
  # (a cluster node's VM is hostname "arquitens" from hosts/arquitens-node,
  # beside the bare-metal hosts/arquitens it replaces).
  mkNixos =
    {
      hostname,
      stateVersion,
      hostDir ? hostname,
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
          hostDir
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
