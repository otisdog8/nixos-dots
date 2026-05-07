# Wine - Run Windows applications and games on Linux
#
# Installs wine-staging (with 32-bit + 64-bit support via wineWowPackages),
# winetricks for installing Windows redistributables, and DXVK/VKD3D for
# Direct3D -> Vulkan translation. Also enables gamemode and mangohud for
# performance tuning and overlays.
#
# Sandboxing is opt-in (off by default in the gaming bundle) since games
# may be installed in arbitrary locations and need broad filesystem access.

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
      name = "wine";
      # wineWow64Packages: new WoW64 mode wine (replaces deprecated wineWowPackages),
      # supports running 32-bit Windows apps on a 64-bit-only host.
      package = pkgs.wineWow64Packages.staging;
      packageName = "wine";

      # Wine prefixes, registry, and downloaded redistributables.
      # The default prefix lives at ~/.wine; users may also point WINEPREFIX
      # elsewhere - those custom prefixes won't auto-persist.
      persistence.user = {
        persist = [
          ".wine"
          ".config/wine"
        ];

        # Game installs and large redistributables can grow significantly.
        large = [
          ".local/share/wineprefixes"
        ];

        cache = [
          ".cache/wine"
          ".cache/winetricks"
        ];
      };

      # Wine needs input devices for controllers/joysticks
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

      customConfig =
        {
          config,
          lib,
          pkgs,
        }:
        {
          # Companion tooling. wineWowPackages.staging only ships wine itself;
          # winetricks, protontricks, dxvk, and vkd3d-proton are separate.
          environment.systemPackages = with pkgs; [
            winetricks
            protontricks
            dxvk
            vkd3d-proton
            # Performance overlay + frame limiter
            mangohud
            # CLI helpers commonly needed when troubleshooting wine
            cabextract
          ];

          # GameMode — request CPU/GPU performance governor while a game runs.
          # Invoke games via `gamemoderun wine game.exe` (or set in Lutris).
          programs.gamemode.enable = true;
        };
    };
  }
)
