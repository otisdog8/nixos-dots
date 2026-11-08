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
      # main.js runs `cp.exec('locale -k LC_TIME')` at startup and does
      # `regex.exec(stdout)[1]` on the result. cp.exec spawns /bin/sh, which a
      # bwrap sandbox doesn't have — the spawn error leaves stdout empty, the
      # match is null, and the uncaught TypeError kills the main process with
      # Electron's "A JavaScript error occurred" dialog. bin-sh.nix provides the
      # shell; the PATH prefix below provides the `locale` binary itself.
      ../../../lib/features/bin-sh.nix
    ];

    config.app = {
      name = "tetrio-desktop";
      # Force native Wayland like vesktop: a dedicated uid can't auth to XWayland, and
      # Electron's hint alone falls back to X11.
      package = pkgs.symlinkJoin {
        name = "tetrio-desktop-wayland";
        paths = [ pkgs.tetrio-desktop ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          rm $out/bin/tetrio
          # --use-angle=vulkan: tetrio's Electron 41 on NVIDIA/Wayland fails every
          # dmabuf import through ANGLE's GL backend (eglCreateImage EGL_BAD_ALLOC →
          # permanent context-lost loop, black window), with the same sandbox binds
          # that render fine for vesktop's Electron 40. ANGLE-on-Vulkan imports
          # dmabufs via VK_EXT_external_memory_dma_buf, which NVIDIA's Vulkan
          # driver handles correctly.
          makeWrapper ${pkgs.tetrio-desktop}/bin/tetrio $out/bin/tetrio \
            --add-flags "--ozone-platform=wayland --use-angle=vulkan" \
            --prefix PATH : ${lib.makeBinPath [ pkgs.glibc.bin ]}
        '';
      };
      packageName = "tetrio";

      # Single-profile Electron app: chromium.nix supplies the whole storage
      # layout (profile → /persist, standard Electron caches → /cache) from
      # basePath = .config/tetrio-desktop (the name-derived default). No per-app
      # storage list needed; the profiles option defaults to [] which is correct
      # here (caches live at basePath, not under a Default/ profile). Dedicated-uid
      # systemd (pure Electron, behaves like vesktop): login/scores run as
      # app-tetrio-desktop, hidden from jrt.
      defaultBackend = "systemd";

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.tetrio-desktop.sandbox.dedicatedUser = true;
        };
    };
  }
)
