# Steam - Gaming platform

(import ../../../lib/apps.nix).mkApp (
  { config, lib, pkgs, ... }: {
    imports = [
      ../../../lib/features/gui.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/network.nix
      ../../../lib/features/audio.nix
      ../../../lib/features/xdg-desktop.nix
    ];

    config.app = {
      name = "steam";
      package = pkgs.steam;
      packageName = "steam";

      # Game library and installations (both go to large)
      persistence.user.large = [
        ".steam"
        ".local/share/Steam"
      ];

      # Enable input devices for game controllers
      nixpakModules = [
        ({ lib, ... }: {
          bubblewrap.bind.dev = [
            "/dev/input"
            "/dev/uinput"
          ];
        })
      ];
    };
  }
)
