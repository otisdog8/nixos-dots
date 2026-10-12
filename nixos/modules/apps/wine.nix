# Wine - Run Windows applications and games on Linux
#
# Installs wine-staging (with 32-bit + 64-bit support via wineWowPackages),
# winetricks for installing Windows redistributables, and DXVK/VKD3D for
# Direct3D -> Vulkan translation. Also enables gamemode and mangohud for
# performance tuning and overlays.

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

      # Unsandboxed: wine runs arbitrary Windows binaries from arbitrary install
      # locations, so a sandbox would only block user-chosen game dirs. The "none"
      # backend keeps storage at ~ via impermanence (host-visible).
      defaultBackend = "none";

      # Wine prefixes, registry, and downloaded redistributables.
      # The default prefix lives at ~/.wine; users may also point WINEPREFIX
      # elsewhere - those custom prefixes won't auto-persist.
      storage = [
        {
          path = ".wine";
          tier = "persist";
        }
        {
          path = ".config/wine";
          tier = "persist";
        }
        # Game installs and large redistributables can grow significantly.
        {
          path = ".local/share/wineprefixes";
          tier = "large";
        }
        {
          path = ".cache/wine";
          tier = "cache";
        }
        {
          path = ".cache/winetricks";
          tier = "cache";
        }
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
