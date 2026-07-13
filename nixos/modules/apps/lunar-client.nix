# Lunar Client - Minecraft PvP client

(import ../../../lib/apps.nix).mkApp (
  {
    config,
    lib,
    pkgs,
    ...
  }:
  {
    imports = [
      # chromium.nix (imports gui.nix) gives the Lunar LAUNCHER's embedded-Electron
      # profile (~/.config/lunarclient) the standard chromium storage shape: the
      # profile on persist (Cookies/Local Storage/prefs = launcher login + settings),
      # its regenerable Chromium caches (Cache/GPUCache/Code Cache/Dawn*/…) carved to
      # /cache as cross-tier children. Same treatment as vesktop et al.
      ../../../lib/features/chromium.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/network.nix
      ../../../lib/features/audio.nix
      ../../../lib/features/xdg-desktop.nix
    ];

    config.app = {
      name = "lunar-client";
      package = pkgs.lunar-client;
      packageName = "lunarclient";

      # The launcher's Electron profile is ~/.config/lunarclient (no hyphen), so the
      # chromium.nix default basePath (.config/${name} = .config/lunar-client) is
      # wrong — point it at the real dir. extraCacheDirs adds the two regenerable
      # caches this app has that aren't in chromium.nix's default carve list.
      chromium.basePath = ".config/lunarclient";
      chromium.extraCacheDirs = [
        "shared_proto_db"
        "VideoDecodeStats"
      ];

      # v2 unified storage (replaces persistence.user.* + impermanence). This app is
      # THE nested-tier desync case: `.lunarclient/offline` and `.lunarclient/jre`
      # (large) live INSIDE `.lunarclient` (persist). Under the legacy path that
      # stacked two independent mount authorities (impermanence home bind + the bwrap
      # mirror) on the same tree, desyncing the live process (the Lunar login desync).
      # In v2 there is ONE authority (bwrap): the stash binds are sorted parent-first
      # and applied in a single namespace, so the child `large` binds mount cleanly on
      # top of the `persist` parent. Cross-tier nesting is explicitly allowed by
      # lib/storage.nix (only SAME-tier nesting is illegal).
      defaultBackend = "nixpak";
      storage = [
        # Settings, mods, resourcepacks (backed up).
        {
          path = ".lunarclient";
          tier = "persist";
        }
        {
          path = ".local/share/lunarclient";
          tier = "persist";
        }
        # Offline game files + bundled JRE: large, persisted but NOT backed up.
        {
          path = ".lunarclient/offline";
          tier = "large";
        }
        {
          path = ".lunarclient/jre";
          tier = "large";
        }
        # NB: ~/.config/lunarclient is NOT declared here — chromium.nix emits it
        # (persist profile + carved /cache children) via chromium.basePath above.
      ];
    };
  }
)
