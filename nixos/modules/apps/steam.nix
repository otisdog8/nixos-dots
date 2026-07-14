# Steam - Gaming platform

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
      ../../../lib/features/audio.nix
      ../../../lib/features/xdg-desktop.nix
      # Proton, game wrapper scripts, and r2modman's modded-launch scripts all exec a
      # hardcoded /bin/sh, absent from a bwrap tmpfs root. Same fix r2modman needs; the
      # full modded-launch chain (steam ↔ r2modman) still wants runtime testing.
      ../../../lib/features/bin-sh.nix
    ];

    config.app = {
      name = "steam";
      package = pkgs.steam;
      packageName = "steam";

      # v2 storage, but every entry is location = "home" (host-visible at ~, NOT a
      # hidden stash). Two reasons this is mandatory:
      #   1. r2modman (a separate same-uid sandbox) binds ~/.steam and
      #      ~/.local/share/Steam rw to install mods into Steam's game dirs — a stash
      #      would hide them from r2modman and break modding. (Full isolation waits on
      #      the steam+r2modman shared-namespace work.)
      #   2. location=home is the SAME impermanence path the legacy layout used, so
      #      converting moves ZERO data — the 135G library stays exactly where it is.
      # Same-uid nixpak (not dedicated): steam runs as jrt so jrt/r2modman can reach
      # the library; the sandbox is the boundary, not host-hiding.
      defaultBackend = "nixpak";
      storage = [
        # Library + installs: large (persisted, not backed up), host-visible.
        {
          path = ".steam";
          tier = "large";
          location = "home";
        }
        {
          path = ".local/share/Steam";
          tier = "large";
          location = "home";
        }
        # Non-Steam-cloud game saves: persist (backed up), host-visible.
        {
          path = ".local/share/FasterThanLight";
          tier = "persist";
          location = "home";
        }
        {
          path = ".local/share/Paradox Interactive/Stellaris";
          tier = "persist";
          location = "home";
        }
      ];

      # Enable input devices for game controllers
      nixpakModules = [
        (
          { lib, sloth, ... }:
          {
            bubblewrap.bind.dev = [
              "/dev/input"
              "/dev/uinput"
            ];

            bubblewrap.bind.rw = [
              # r2modman mod data
              (sloth.concat' sloth.homeDir "/.config/r2modmanPlus-local")
            ];
          }
        )
      ];

      # Gamescope — micro-compositor for running games in an isolated Wayland
      # session (upscaling, frame limiting, HDR). Enabling it here installs the
      # binary with the CAP_SYS_NICE capability needed for realtime scheduling.
      # Use via Steam per-game launch options: `gamescope -- %command%`.
      customConfig =
        { ... }:
        {
          programs.gamescope.enable = true;
        };
    };
  }
)
