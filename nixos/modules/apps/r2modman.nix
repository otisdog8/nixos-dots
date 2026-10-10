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
      # r2modman runs its launch command through the hardcoded /bin/sh, which a
      # bwrap tmpfs root lacks (same fix as steam.nix).
      ../../../lib/features/bin-sh.nix
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

      # Launch through Steam, not by running it. Natively r2modman runs
      # "<Steam dir>/steam.sh -applaunch <id> <mod args>" itself, which can't work
      # in a sandbox: steam.sh needs Steam's FHS runtime (/usr/bin/env, the 32-bit
      # client), and would start a second Steam. With FLATPAK_ID set it takes its
      # Flatpak path instead: it writes the mod args to
      # ~/.config/r2modmanPlus-local/wrapper_args.txt and opens steam://run/<id>
      # through the OpenURI portal (xdg-open: open-links.nix in a container, the
      # guest's portal-mode xdg-open in a VM). The host's steam:// handler is
      # Steam's own launcher (steam.nix), which starts Steam if it isn't running
      # and runs the game with its launch options: "<…>/web_start_wrapper.sh"
      # %command% (set once per game; r2modman shows the line) reads the args back.
      # Containers: Steam's sandbox binds ~/.config/r2modmanPlus-local. VMs: run
      # both in the `games` group VM (bundles/gaming.nix), one guest home for both.
      # FLATPAK_ID also turns off r2modman's self-updater; only its presence counts.
      environment.FLATPAK_ID = "com.github.ebkr.r2modman";

      # Containers: game files, app manifests, the Steam user's launch options
      # (which r2modman checks) and Proton prefixes (it adds the mod loader's DLL
      # override to user.reg). In the group VM these are the shared guest home.
      nixpakModules = [
        (
          { sloth, ... }:
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
