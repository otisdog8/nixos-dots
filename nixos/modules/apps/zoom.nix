# Zoom video conferencing — dedicated-uid sandbox, persistent config

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
      ../../../lib/features/microphone.nix
      ../../../lib/features/camera.nix
      ../../../lib/features/screen-capture.nix
      ../../../lib/features/xdg-desktop.nix
      ../../../lib/features/system-tray.nix
    ];

    config.app = {
      name = "zoom";
      package = pkgs.zoom-us;
      packageName = "zoom";

      # Dedicated-uid, persistent: login/settings (.zoom + .config) run as app-zoom —
      # hidden from a compromised jrt — and kept across reboots. Screen share rides
      # the PipeWire portal (works cross-uid already).
      defaultBackend = "systemd";
      storage = [
        {
          path = ".zoom";
          tier = "persist";
        }
        # zoom.conf / zoomus.conf live here. Persist the DIRECTORY, not the two
        # files: Qt's QSettings saves via write-temp-then-rename(), and renaming
        # over a single-file bind mount fails (EBUSY), so settings never stuck.
        # The home belongs to app-zoom alone, so the whole .config is safe to keep.
        {
          path = ".config";
          tier = "persist";
        }
      ];

      # Drive Qt onto XCB/XWayland (not native Wayland): zoom's bundled Qt6 segfaulted a
      # child on native Wayland, and a dedicated uid can only reach XWayland via the
      # x11Forward grant (customConfig below). QT_QPA_PLATFORM=xcb + x11Forward is the
      # working combo; the socket/auth for it is set up by the launcher.
      nixpakModules = [
        (
          { ... }:
          {
            bubblewrap.env.QT_QPA_PLATFORM = "xcb";
          }
        )
      ];

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.zoom.sandbox.dedicatedUser = true;
          modules.apps.zoom.sandbox.x11Forward = true;
          users.users."app-zoom".extraGroups = [
            "video"
            "audio"
          ];
        };
    };
  }
)
