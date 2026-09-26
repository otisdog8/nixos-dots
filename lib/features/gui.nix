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
    # Backend-agnostic: the VM backend wires the display from this (the bwrap
    # backends get the same socket from the nixpak module below too).
    capabilities.wayland = true;

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
              # Device access. GPU device nodes deliberately NOT bound here —
              # they come from the `gpu` capability (needs-gpu.nix), which is
              # the single place modules.sandbox.gpuDevices can narrow on
              # multi-GPU hosts (a blanket /dev/dri here re-exposed the hidden
              # card and broke that narrowing). gui-without-gpu apps (ark,
              # protonvpn-gui, slipstream) software-render — they never had
              # /run/opengl-driver from this feature anyway.
              dev = [
              ];

              # Read-write bind mounts
              rw = [
              ];

              # Read-only bind mounts
              # All soft binds (nixpak bind.ro = --ro-bind-try): a path that
              # doesn't exist for this app's HOME/host is skipped, not fatal.
              # No /tmp/.X11-unix here: X11 is the separate `x11` capability
              # (features/x11.nix, or sandbox.x11Forward), so Wayland-only apps
              # don't get the X socket.
              ro = [
                "/run/current-system/sw/share/fonts"
                "/etc/localtime"
                "/etc/zoneinfo"
                (sloth.concat' sloth.xdgConfigHome "/gtk-2.0")
                (sloth.concat' sloth.xdgConfigHome "/gtk-3.0")
                (sloth.concat' sloth.xdgConfigHome "/gtk-4.0")
                (sloth.concat' sloth.xdgConfigHome "/fontconfig")
                (sloth.concat' sloth.xdgConfigHome "/dconf")
                # Qt theming config (qt6ct picks the Kvantum/Sweet look). Present in
                # jrt's config for same-uid apps; harmlessly skipped for dedicated
                # apps until per-user Qt config is shared like the vault.
                (sloth.concat' sloth.xdgConfigHome "/qt6ct")
                (sloth.concat' sloth.xdgConfigHome "/Kvantum")
              ]
              # GTK theme data (Sweet) + Kvantum themes + icons, so a sandboxed GTK/Qt
              # app can actually FIND the theme its config names (the config binds
              # above say WHICH theme; these carry the files). Bound from the system
              # profile with absolute paths, so they work for dedicated apps too (whose
              # HOME is /home/app-<name>, not jrt's). The subpaths come from
              # lib/sandbox-theme-paths.nix — the SAME list theming.nix feeds into
              # environment.pathsToLink, so the bind side and the link side can't
              # desync into a silent Adwaita fallback.
              ++ map (p: "/run/current-system/sw" + p) (import ../sandbox-theme-paths.nix);
            };

            # Environment variables. Use envOr (with fallbacks) not env: the
            # nixpak launcher PANICS on a referenced-but-unset var, and the
            # systemd/dedicated backends run with a minimal Nix-derived env rather
            # than the full session. In-session apps still get the real session
            # value; only a missing var falls back.
            env = {
              DISPLAY = sloth.envOr "DISPLAY" ":0";
              WAYLAND_DISPLAY = sloth.envOr "WAYLAND_DISPLAY" "wayland-0";
              LANG = sloth.envOr "LANG" "C.UTF-8";

              # Qt theming/display for sandboxed Qt apps. In-session apps inherit the
              # live session value (envOr); dedicated/systemd apps run on a minimal env
              # and fall back to these. qt6ct is the platform theme that reads the
              # qt6ct/Kvantum config bound in above (ro binds), so Qt apps pick up the
              # Sweet/Kvantum look instead of default Fusion. QT_QPA_PLATFORM is
              # mkDefault so per-app overrides win (zoom forces xcb, obs forces wayland).
              QT_QPA_PLATFORMTHEME = sloth.envOr "QT_QPA_PLATFORMTHEME" "qt6ct";
              QT_QPA_PLATFORM = lib.mkDefault (sloth.envOr "QT_QPA_PLATFORM" "wayland;xcb");
              # Force chromium/electron onto Wayland. In-session apps inherit
              # NIXOS_OZONE_WL from the session; systemd/dedicated apps run on a
              # minimal env, so without this electron falls back to X11 (which has
              # no Xauth in the sandbox → no window). Literal, harmless for
              # non-electron GUI apps.
              NIXOS_OZONE_WL = "1";
              ELECTRON_OZONE_PLATFORM_HINT = "wayland";
              # Firefox/gecko native Wayland (hard enable, no X11 fallback).
              # Harmless for non-gecko apps.
              MOZ_ENABLE_WAYLAND = "1";
              # Portal/ScreenCast detection: chromium/electron pick the PipeWire
              # portal screen capturer (vs X11) based on the desktop/session type.
              # The dedicated backend's minimal env lacks these, so default to the
              # compositor (Hyprland) / wayland; in-session apps inherit the real
              # session value via envOr.
              XDG_CURRENT_DESKTOP = sloth.envOr "XDG_CURRENT_DESKTOP" "Hyprland";
              XDG_SESSION_TYPE = sloth.envOr "XDG_SESSION_TYPE" "wayland";
            };
          };
        }
      )
    ];
  };
}
