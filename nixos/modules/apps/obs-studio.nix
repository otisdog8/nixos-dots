# OBS Studio - Screen recording and streaming

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
      package = pkgs.wrapOBS.override { obs-studio = pkgs.obs-studio; } {
        plugins = with pkgs.obs-studio-plugins; [
          wlrobs
          obs-backgroundremoval
          obs-pipewire-audio-capture
        ];
      };
      packageName = "obs";

      # OBS config and scenes
      persistence.user.persist = [
        ".config/obs-studio"
      ];

      # Additional NixOS configuration
      customConfig =
        {
          config,
          lib,
          pkgs,
        }:
        {
          # System-level OBS configuration
          # Pass null as package since our sandboxed package is already in systemPackages
          # Plugins are configured outside this module
          programs.obs-studio = {
            enable = true;
            enableVirtualCamera = true;
            package = null;
          };
        };
    };
  }
)
