# Zen Browser (Firefox/gecko-based) — dedicated-uid sandbox, persistent profile

(import ../../../lib/apps.nix).mkApp (
  {
    config,
    lib,
    pkgs,
    ...
  }:
  {
    imports = [
      ../../../lib/features/browser.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/xdg-desktop.nix
      ../../../lib/features/onepassword.nix
    ];

    config.app = {
      name = "zen-browser";
      package = pkgs.zen-browser;
      # The package ships ONLY bin/zen-beta, and zen-beta.desktop runs `zen-beta` —
      # so that's the binary the systemd launcher must wrap (the old "zen" name only
      # worked in the legacy nixpak path via extraEntrypoints, which systemd ignores).
      packageName = "zen-beta";
      desktopFileName = "zen-beta.desktop";
      # gecko registers org.mozilla.<app>.<profile-instance> on the session bus
      # (MOZ_DBUS_REMOTE, set by open-links.nix); the launcher resolves the live
      # instance from this prefix to forward URLs to a running window. Verify with
      # `busctl --user list | grep -i zen` if link-forwarding misses.
      dbusName = "org.mozilla.zen";

      # Dedicated-uid, PERSISTENT: the .zen profile (logins/tabs/history) runs as
      # app-zen-browser — DAC-hidden from a compromised jrt — and is kept across
      # reboots via the stash. gecko goes native-Wayland through MOZ_ENABLE_WAYLAND
      # (gui.nix) with its built-in portal ScreenCast — no --ozone wrapper needed
      # (unlike the chromium/electron apps). The disk cache lives in ~/.cache (not in
      # the stash), so it's disposable on the app's ephemeral home.
      # Whole .zen profile on persist (backed up). It's ~1G, mostly storage/ (site
      # IndexedDB + Cache API); gecko's random profile name (<hash>.Default Profile)
      # blocks carving out just the disposable bits, and the profile is wanted in the
      # backup, so it stays whole on persist.
      defaultBackend = "systemd";
      storage = [
        {
          path = ".zen";
          tier = "persist";
        }
      ];

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.zen-browser.sandbox.dedicatedUser = true;
          users.users."app-zen-browser".extraGroups = [
            "video"
            "audio"
          ];
        };
    };
  }
)
