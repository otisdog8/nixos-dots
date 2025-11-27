# OBS Studio - Screen recording and streaming

(import ../../../lib/apps.nix).mkApp (
  { config, lib, pkgs, ... }: {
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
      package = pkgs.obs-studio;
      packageName = "obs";

      # OBS config and scenes
      persistence.user.persist = [
        ".config/obs-studio"
      ];

      # Additional NixOS and home-manager configuration
      customConfig = { config, lib, pkgs }: {
        # NixOS level configuration
        programs.obs-studio = {
          enable = true;
          enableVirtualCamera = true;
        };

        # Home-manager level configuration
        home-manager.users.jrt.programs.obs-studio = {
          enable = true;
          plugins = with pkgs.obs-studio-plugins; [
            wlrobs
            obs-backgroundremoval
            obs-pipewire-audio-capture
          ];
        };
      };
    };
  }
)
