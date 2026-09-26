# Tmpfs home directory - all data cleared when the app exits.
# This feature mounts the home directory as tmpfs in the sandbox.
#
# Binds under $HOME (e.g. sandbox.sharedDownloads) still appear on top of the
# tmpfs: our patched nixpak mounts tmpfs before binds (lib/backends/nixpak-pkg.nix).
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app = {
    # Nothing is persisted: storage would only be shadowed by the tmpfs.
    storage = lib.mkForce [ ];

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
