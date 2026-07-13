# OBS Studio - screen recording/streaming — dedicated-uid sandbox, persistent config

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
      ../../../lib/features/camera.nix
      ../../../lib/features/screen-capture.nix
      ../../../lib/features/xdg-desktop.nix
    ];

    config.app = {
      name = "obs-studio";
      # Wrap OBS with plugins before sandboxing
      package = pkgs.wrapOBS.override { inherit (pkgs) obs-studio; } {
        plugins = with pkgs.obs-studio-plugins; [
          wlrobs
          obs-backgroundremoval
          obs-pipewire-audio-capture
        ];
      };
      packageName = "obs";

      # Dedicated-uid, persistent: scenes + settings AND stream keys (.config/
      # obs-studio) run as app-obs-studio, hidden from a compromised jrt, kept across
      # reboots. Screen capture rides the PipeWire portal (cross-uid, like screenshare
      # elsewhere); the virtual camera writes /dev/video* (bound by camera.nix, video
      # group below). v4l2loopback itself is set up system-wide by enableVirtualCamera.
      defaultBackend = "systemd";
      storage = [
        {
          path = ".config/obs-studio";
          tier = "persist";
        }
      ];

      # Force Qt onto native Wayland (XWayland needs a cross-uid X-auth the dedicated
      # uid lacks). OBS then captures via wlrobs / the PipeWire portal on Wayland.
      nixpakModules = [
        (
          { ... }:
          {
            bubblewrap.env.QT_QPA_PLATFORM = "wayland";
          }
        )
      ];

      customConfig =
        { config, lib, ... }:
        {
          # System-level v4l2loopback virtual-camera setup (our sandboxed package is
          # already in systemPackages, so package = null).
          programs.obs-studio = {
            enable = true;
            enableVirtualCamera = true;
            package = null;
          };

          modules.apps.obs-studio.sandbox.dedicatedUser = true;
          users.users."app-obs-studio".extraGroups = [
            "video"
            "audio"
          ];
        };
    };
  }
)
