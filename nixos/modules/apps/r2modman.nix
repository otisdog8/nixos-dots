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
      # TEMP FIX: r2modman launches games through a shell wrapper that execs the
      # hardcoded /bin/sh, which a bwrap tmpfs root lacks → "missing /bin/sh" on game
      # launch. bin-sh.nix binds a bash ELF onto /bin/sh. The REAL fix lands with the
      # steam conversion (r2modman launches games via Steam; the shared game-launch
      # environment gets sorted out there) — revisit then.
      ../../../lib/features/bin-sh.nix
    ];

    config.app = {
      name = "r2modman";
      package = pkgs.r2modman;
      packageName = "r2modman";

      # v2 unified storage. location = "home" (NOT a hidden stash) is load-bearing:
      # r2modman's mod data is SHARED with steam (steam binds ~/.config/
      # r2modmanPlus-local rw so it can launch modded games). steam stays legacy with
      # its data at jrt's real $HOME, so r2modman's copy must also stay host-visible at
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
