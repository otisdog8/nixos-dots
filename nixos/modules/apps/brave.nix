# Brave web browser

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
      name = "brave";
      # Force native Wayland (a dedicated uid can't auth to XWayland) + PipeWire
      # screen capturer, exactly as zen/ungoogled-chromium do.
      package = pkgs.symlinkJoin {
        name = "brave-wayland";
        paths = [ pkgs.brave ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          rm $out/bin/brave
          makeWrapper ${pkgs.brave}/bin/brave $out/bin/brave \
            --add-flags "--ozone-platform=wayland --enable-features=WebRtcPipeWireCapturer"
        '';
      };
      packageName = "brave";
      desktopFileName = "brave-browser.desktop";

      # Brave keeps its profile under .config/BraveSoftware/Brave-Browser, with the
      # real per-profile caches under Default/. profiles=["Default"] makes chromium.nix
      # carve them (Cache/Code Cache/GPUCache/Dawn*/Service Worker/CacheStorage) to
      # /cache — replacing the old hand-listed persistence.user.cache entry.
      chromium.basePath = ".config/BraveSoftware/Brave-Browser";
      chromium.profiles = [ "Default" ];

      # Dedicated-uid + persistent: logins/passwords/history run as app-brave, hidden
      # from a compromised jrt, kept across reboots via the stash (like zen). chromium
      # profile persisted, caches carved to /cache (chromium.nix).
      defaultBackend = "systemd";

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.brave.sandbox.dedicatedUser = true;
          users.users."app-brave".extraGroups = [
            "video"
            "audio"
          ];
        };
    };
  }
)
