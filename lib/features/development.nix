# Development tool feature
{ config, lib, ... }:

{
  imports = [
    ./gui.nix
    ./network.nix
  ];

  config.app = {
    # Dev tools typically need config and data persistence
    persistence.user.persist = lib.mkDefault [
      ".config/${config.app.name}"
      ".local/share/${config.app.name}"
    ];

    persistence.user.cache = lib.mkDefault [
      ".cache/${config.app.name}"
    ];

    # Dev tools often need broader filesystem access
    # Light sandboxing by default
  };
}
