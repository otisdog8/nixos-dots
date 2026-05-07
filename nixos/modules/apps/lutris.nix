# Lutris - Open source game manager / launcher for Wine, emulators, and more
#
# Wraps Lutris with the runtime libraries it needs (wine, mesa drivers, etc.)
# Pairs naturally with the wine.nix module - Lutris uses wine under the hood
# but can also manage its own per-prefix wine builds.

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
    ];

    config.app = {
      name = "lutris";
      package = pkgs.lutris;
      packageName = "lutris";

      persistence.user = {
        # Lutris config and game library metadata
        persist = [
          ".config/lutris"
          ".local/share/lutris"
        ];

        # Game installs and per-game wine prefixes
        large = [
          "Games"
        ];

        cache = [
          ".cache/lutris"
        ];
      };

      nixpakModules = [
        (
          { lib, ... }:
          {
            bubblewrap.bind.dev = [
              "/dev/input"
              "/dev/uinput"
            ];
          }
        )
      ];
    };
  }
)
