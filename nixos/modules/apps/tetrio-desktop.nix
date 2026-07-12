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
      package = pkgs.tetrio-desktop;
      packageName = "tetrio";

      # Single-profile Electron app: chromium.nix supplies the whole storage
      # layout (profile → /persist, standard Electron caches → /cache) from
      # basePath = .config/tetrio-desktop (the name-derived default). No per-app
      # storage list needed; the profiles option defaults to [] which is correct
      # here (caches live at basePath, not under a Default/ profile).
      defaultBackend = "nixpak";
    };
  }
)
