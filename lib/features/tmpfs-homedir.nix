# Tmpfs home directory - all data cleared on reboot
# This feature mounts the home directory as tmpfs in the sandbox
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app = {
    # Clear all persistence - nothing should be saved
    persistence.user.persist = lib.mkForce [ ];
    persistence.user.large = lib.mkForce [ ];
    persistence.user.cache = lib.mkForce [ ];
    persistence.user.baked = lib.mkForce [ ];

    nixpakModules = [
      (
        { lib, sloth, ... }:
        {
          # Mount home directory as tmpfs
          bubblewrap.tmpfs = [
            sloth.homeDir
          ];
        }
      )
    ];
  };
}
