# Ungoogled Chromium - ephemeral browser with tmpfs homedir

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
      ../../../lib/features/tmpfs-homedir.nix
    ];

    config.app = {
      name = "ungoogled-chromium";
      # Force native Wayland (hint alone falls back to XWayland, which a dedicated
      # uid can't auth to) + the PipeWire screen capturer (portal ScreenCast).
      package = pkgs.symlinkJoin {
        name = "ungoogled-chromium-wayland";
        paths = [ pkgs.ungoogled-chromium ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          rm $out/bin/chromium
          makeWrapper ${pkgs.ungoogled-chromium}/bin/chromium $out/bin/chromium \
            --add-flags "--ozone-platform=wayland --enable-features=WebRtcPipeWireCapturer"
        '';
      };
      packageName = "chromium";
      desktopFileName = "chromium-browser.desktop";

      # Dedicated-uid + ephemeral: runs as app-ungoogled-chromium (data hidden from
      # jrt) with a tmpfs home wiped on reboot. Clear chromium.nix's persist storage
      # so no stash is created/backed-up (the tmpfs home would only shadow it).
      defaultBackend = "systemd";
      storage = lib.mkForce [ ];

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.ungoogled-chromium.sandbox.dedicatedUser = true;
          users.users."app-ungoogled-chromium".extraGroups = [
            "video"
            "audio"
          ];
        };
    };
  }
)
