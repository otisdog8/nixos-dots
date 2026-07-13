# TETR.IO Desktop - Online stacker game

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
      name = "tetrio-desktop";
      # EXPERIMENT (dedicated-uid): force native Wayland like vesktop — a dedicated
      # uid can't auth to XWayland, and Electron's hint alone falls back to X11.
      package = pkgs.symlinkJoin {
        name = "tetrio-desktop-wayland";
        paths = [ pkgs.tetrio-desktop ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          rm $out/bin/tetrio
          makeWrapper ${pkgs.tetrio-desktop}/bin/tetrio $out/bin/tetrio \
            --add-flags "--ozone-platform=wayland"
        '';
      };
      packageName = "tetrio";

      # Single-profile Electron app: chromium.nix supplies the whole storage
      # layout (profile → /persist, standard Electron caches → /cache) from
      # basePath = .config/tetrio-desktop (the name-derived default). No per-app
      # storage list needed; the profiles option defaults to [] which is correct
      # here (caches live at basePath, not under a Default/ profile).
      #
      # EXPERIMENT: dedicated-uid systemd (was nixpak same-uid). Pure Electron, so it
      # should behave like vesktop (native Wayland works cross-uid). Login/scores run
      # as app-tetrio-desktop, hidden from jrt. Revert to `defaultBackend = "nixpak"`
      # + drop the wrapper/customConfig if the game misbehaves cross-uid.
      defaultBackend = "systemd";

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.tetrio-desktop.sandbox.dedicatedUser = true;
          users.users."app-tetrio-desktop".extraGroups = [
            "video"
            "audio"
          ];
        };
    };
  }
)
