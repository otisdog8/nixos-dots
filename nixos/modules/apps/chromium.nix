# Chromium web browser

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
      ../../../lib/features/browser.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/xdg-desktop.nix
      ../../../lib/features/onepassword-chromium.nix
    ];

    config.app = {
      name = "chromium";
      # Force native Wayland (a dedicated uid can't auth to XWayland) + PipeWire
      # screen capturer, exactly as zen/ungoogled-chromium do.
      package = pkgs.symlinkJoin {
        name = "chromium-wayland";
        paths = [ pkgs.chromium ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          rm $out/bin/chromium
          makeWrapper ${pkgs.chromium}/bin/chromium $out/bin/chromium \
            --add-flags "--ozone-platform=wayland --enable-features=WebRtcPipeWireCapturer"
        '';
      };
      packageName = "chromium";
      desktopFileName = "chromium-browser.desktop";

      # basePath defaults to .config/chromium (correct). Caches live under Default/,
      # so profiles=["Default"] carves them (Cache/Code Cache/GPUCache/Dawn*/Service
      # Worker/CacheStorage) to /cache.
      chromium.profiles = [ "Default" ];

      # Dedicated-uid + persistent, mirroring brave/zen: profile hidden from jrt and
      # kept across reboots; caches carved to /cache by chromium.nix.
      defaultBackend = "systemd";

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.chromium.sandbox.dedicatedUser = true;
          users.users."app-chromium".extraGroups = [
            "video"
            "audio"
          ];
        };
    };
  }
)
