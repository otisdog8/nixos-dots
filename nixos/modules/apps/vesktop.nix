# Vesktop (third-party Discord client)

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
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/network.nix
      ../../../lib/features/audio.nix
      ../../../lib/features/screen-capture.nix
      ../../../lib/features/camera.nix
      ../../../lib/features/xdg-desktop.nix
      ../../../lib/features/x11.nix
      ../../../lib/features/system-tray.nix
    ];

    config.app = {
      name = "vesktop";
      # Force NATIVE Wayland. gui.nix's ELECTRON_OZONE_PLATFORM_HINT=wayland is only
      # a HINT (allows X11 fallback), and vesktop's Electron 40 takes it → runs on
      # XWayland, which needs a cross-uid X-auth the dedicated uid doesn't have. The
      # hard `--ozone-platform=wayland` removes the X11 fallback entirely.
      package = pkgs.symlinkJoin {
        name = "vesktop-wayland";
        paths = [ pkgs.vesktop ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          rm $out/bin/vesktop
          makeWrapper ${pkgs.vesktop}/bin/vesktop $out/bin/vesktop \
            --add-flags "--ozone-platform=wayland --enable-features=WebRtcPipeWireCapturer"
        '';
      };
      packageName = "vesktop";

      # Dedicated-uid stash: the Discord token (sessionData/Local Storage) is
      # DAC-hidden from a compromised jrt. Works cross-uid because the Wayland
      # force above puts Electron on NATIVE Wayland (no X server / X-auth needed) —
      # XWayland was what broke the dedicated uid.
      defaultBackend = "systemd";

      # The Electron profile is a SUBDIR (sessionData); the real persist root is
      # the parent (Vencord settings/themes/state), and Crashpad sits outside the
      # profile. chromium.nix carves the ~1.7G of sessionData caches to /cache.
      chromium.basePath = ".config/vesktop/sessionData";
      chromium.persistRoot = ".config/vesktop";
      chromium.extraCacheDirs = [ "Crashpad" ];

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.vesktop.sandbox.dedicatedUser = true;
          # app-vesktop needs device access for camera (/dev/video*) and any ALSA
          # fallback; mic itself rides the ACL'd PipeWire socket.
          users.users."app-vesktop".extraGroups = [
            "video"
            "audio"
          ];
        };
    };
  }
)
