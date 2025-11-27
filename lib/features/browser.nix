# Web browser feature
{ config, lib, ... }:

{
  # Browsers are GUI apps with network
  imports = [
    ./gui.nix
    ./network.nix
  ];

  config.app = {
    # Browser-specific nixpak configuration
    nixpakModules = [
      ({ config, lib, pkgs, sloth, ... }: {
        # Browsers need access to downloads
        bubblewrap.bind.rw = [ (sloth.concat' sloth.homeDir "/Downloads") ];
      })
    ];
  };
}
