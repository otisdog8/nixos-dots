# r2modman - Game mod manager (Risk of Rain 2, Lethal Company, etc.)

(import ../../../lib/apps.nix).mkApp (
  {
    config,
    lib,
    pkgs,
    ...
  }:
  {
    imports = [
      ../../../lib/features/gui.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/network.nix
      ../../../lib/features/xdg-desktop.nix
      # r2modman launches games through a shell wrapper that execs the hardcoded
      # /bin/sh, which a bwrap tmpfs root lacks (same fix as steam.nix).
      ../../../lib/features/bin-sh.nix
      # r2modman runs steam.sh inside its OWN sandbox when Steam isn't already
      # up, and the Steam client is X11/XWayland-only (see steam.nix).
      ../../../lib/features/x11.nix
    ];

    config.app = {
      name = "r2modman";
      package = pkgs.r2modman;
      packageName = "r2modman";

      # location = "home" (NOT a hidden stash) is load-bearing: r2modman's mod data
      # is SHARED with steam (steam binds ~/.config/r2modmanPlus-local rw so it can
      # launch modded games). steam keeps its data at jrt's real $HOME
      # (location = "home"), so r2modman's copy must also stay host-visible at
      # ~/.config/r2modmanPlus-local — a stash would hide it from steam and break the
      # sharing. tier = persist keeps it backed up; location = home keeps it shareable.
      # (Full stash isolation waits on the steam+r2modman shared-namespace work.)
      defaultBackend = "nixpak";
      storage = [
        {
          path = ".config/r2modmanPlus-local";
          tier = "persist";
          location = "home";
        }
      ];

      # Access to Steam paths for game files
      nixpakModules = [
        (
          { lib, sloth, ... }:
          {
            bubblewrap.bind.rw = [
              (sloth.concat' sloth.homeDir "/.steam")
              (sloth.concat' sloth.homeDir "/.local/share/Steam")
            ];
          }
        )
      ];
    };
  }
)
