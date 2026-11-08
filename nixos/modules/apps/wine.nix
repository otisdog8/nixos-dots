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
  let
    # Without their .desktop entries. wine.desktop and protontricks-launch.desktop
    # register as the handler for .exe/.msi/.bat/.lnk, and the desktop portal
    # opens a file with the only handler without asking, so a sandboxed app
    # could hand the host's unsandboxed wine a Windows binary to run. Start
    # things with `wine …` (or wine-vm) explicitly instead.
    noDesktop =
      pkg:
      pkgs.symlinkJoin {
        name = "${pkg.name}-no-desktop";
        paths = [ pkg ];
        postBuild = "rm -rf $out/share/applications";
      };
  in
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
      #
      # winemenubuilder off (every wine command wrapped with
      # WINEDLLOVERRIDES=winemenubuilder.exe=d): it writes the prefixes'
      # programs and file associations into ~/.local/share/applications and
      # ~/.local/share/mime, which would make the unsandboxed wine a file
      # handler again, the way the .desktop entries above did. Entries it made
      # before stay until removed: ~/.local/share/applications/wine*,
      # ~/.local/share/mime/packages/x-wine*, ~/.config/menus/applications-merged/wine*.
      package =
        let
          wine = pkgs.wineWow64Packages.staging;
        in
        pkgs.symlinkJoin {
          name = "${wine.name}-no-menubuilder";
          paths = [ (noDesktop wine) ];
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postBuild = ''
            for f in ${wine}/bin/*; do
              [ -f "$f" ] && [ -x "$f" ] || continue
              rm "$out/bin/$(basename "$f")"
              makeWrapper "$f" "$out/bin/$(basename "$f")" \
                --suffix WINEDLLOVERRIDES ";" "winemenubuilder.exe=d"
            done
          '';
        };
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
            (noDesktop protontricks)
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
