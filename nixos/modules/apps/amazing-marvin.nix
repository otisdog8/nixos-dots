# Amazing Marvin - Task management and productivity app

(import ../../../lib/apps.nix).mkApp (
  {
    config,
    lib,
    pkgs,
    ...
  }:
  {
    imports = [
      ../../../lib/features/chromium.nix
      ../../../lib/features/gui.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/network.nix
      ../../../lib/features/audio.nix
      ../../../lib/features/xdg-desktop.nix
    ];

    config.app = {
      name = "amazing-marvin";
      # Force native Wayland like vesktop: a dedicated uid can't auth to XWayland, and
      # Electron's hint alone falls back to X11.
      package = pkgs.symlinkJoin {
        name = "amazing-marvin-wayland";
        paths = [ pkgs.otisdog8.amazing-marvin ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          rm $out/bin/amazing-marvin
          makeWrapper ${pkgs.otisdog8.amazing-marvin}/bin/amazing-marvin $out/bin/amazing-marvin \
            --add-flags "--ozone-platform=wayland"
        '';
      };
      packageName = "amazing-marvin";

      # Marvin uses .config/Marvin (profile == persist root). chromium.nix supplies
      # the whole storage layout; no per-app cache list needed. Dedicated-uid systemd
      # (pure Electron, behaves like vesktop): account/login runs as app-amazing-marvin,
      # hidden from jrt.
      defaultBackend = "systemd";
      chromium.basePath = ".config/Marvin";

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.amazing-marvin.sandbox.dedicatedUser = true;
          users.users."app-amazing-marvin".extraGroups = [
            "video"
            "audio"
          ];
        };
    };
  }
)
