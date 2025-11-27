# Web browser feature
{ config, lib, ... }:

{
  # Browsers are GUI apps with network
  imports = [
    ./gui.nix
    ./network.nix
  ];

  config.app = {
    # Browsers have extensive cache needs
    persistence.user.cache = [
      ".cache/${config.app.name}"
      ".config/${config.app.name}/Default/Service Worker"
      ".config/${config.app.name}/Service Worker"
      ".config/${config.app.name}/ShaderCache"
    ];

    # Browser-specific nixpak configuration
    nixpakModules = [
      ({ config, lib, pkgs, sloth, ... }: {
        # Browsers need access to downloads
        bubblewrap.bind.rw = [ (sloth.concat' sloth.homeDir "/Downloads") ];
      })
    ];
  };
}
