# GUI application feature
{ config, lib, ... }:

{
  imports = [
    ../app-spec.nix
    ./open-links.nix
    # NOTE: fido.nix (raw /dev/hidraw*) is deliberately NOT pulled in here.
    # GUI-ness does not imply needing security keys; browsers get it via
    # browser.nix, and any other app that needs it imports fido.nix explicitly.
  ];

  config.app = {
    # GUI apps should specify their own persistence paths
    # (removed automatic .config/${name} and .cache/${name} defaults)

    # Nixpak configuration for GUI apps
    nixpakModules = [
      (
        {
          config,
          lib,
          pkgs,
          sloth,
          ...
        }:
        {
          # System integration
          fonts.enable = true;
          locale.enable = true;

          # Bubblewrap sandbox configuration
          bubblewrap = {
            # API VFS for device/process access
            apivfs = {
              dev = true;
              proc = true;
            };

            # Wayland only. Audio (pulse+pipewire, which is also MIC access) is NOT
            # implied by gui — it's the `audio` capability (features/audio.nix), so
            # apps that don't play/record sound don't get microphone access.
            sockets = {
              wayland = true;
            };

            # Bind mounts
            bind = {
              # Device access
              dev = [
                "/dev/dri" # GPU for rendering
              ];

              # Read-write bind mounts
              rw = [
              ];

              # Read-only bind mounts
              ro = [
                "/tmp/.X11-unix"
                "/run/current-system/sw/share/icons"
                "/run/current-system/sw/share/fonts"
                "/etc/localtime"
                "/etc/zoneinfo"
                (sloth.concat' sloth.xdgConfigHome "/gtk-2.0")
                (sloth.concat' sloth.xdgConfigHome "/gtk-3.0")
                (sloth.concat' sloth.xdgConfigHome "/gtk-4.0")
                (sloth.concat' sloth.xdgConfigHome "/fontconfig")
                (sloth.concat' sloth.xdgConfigHome "/dconf")
              ];
            };

            # Environment variables. Use envOr (with fallbacks) not env: the
            # nixpak launcher PANICS on a referenced-but-unset var, and the
            # systemd/dedicated backends run with a minimal Nix-derived env rather
            # than the full session. In-session apps still get the real session
            # value; only a missing var falls back.
            env = {
              DISPLAY = sloth.envOr "DISPLAY" ":0";
              WAYLAND_DISPLAY = sloth.envOr "WAYLAND_DISPLAY" "wayland-0";
              QT_QPA_PLATFORMTHEME = sloth.envOr "QT_QPA_PLATFORMTHEME" "";
              LANG = sloth.envOr "LANG" "C.UTF-8";
              # Force chromium/electron onto Wayland. In-session apps inherit
              # NIXOS_OZONE_WL from the session; systemd/dedicated apps run on a
              # minimal env, so without this electron falls back to X11 (which has
              # no Xauth in the sandbox → no window). Literal, harmless for
              # non-electron GUI apps.
              NIXOS_OZONE_WL = "1";
              ELECTRON_OZONE_PLATFORM_HINT = "wayland";
            };
          };
        }
      )
    ];
  };
}
