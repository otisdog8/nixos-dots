# Development tool feature
{ config, lib, ... }:

{
  imports = [
    ./gui.nix
    ./network.nix
  ];

  config.app = {
    # Dev tools typically need config and data persistence
    persistence.user.persist = [
      ".config/${config.app.name}"
      ".local/share/${config.app.name}"
    ];

    persistence.user.cache = [
      ".cache/${config.app.name}"
    ];

    # Dev tools often need broader filesystem access
    # This is a lighter sandbox by default
    nixpakModules = [
      ({ config, lib, sloth, ... }: {
        # Allow access to common development directories
        bubblewrap.bind.rw = [
          (sloth.concat' sloth.homeDir "/projects")
          (sloth.concat' sloth.homeDir "/code")
          (sloth.concat' sloth.homeDir "/src")
        ];
      })
    ];
  };
}
