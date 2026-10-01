# Zen Browser (Firefox/gecko-based) — dedicated-uid sandbox, persistent profile

(import ../../../lib/apps.nix).mkApp (
  {
    config,
    lib,
    pkgs,
    ...
  }:
  let
    browserSettings = import ../../../lib/browser-settings.nix { inherit lib; };
  in
  {
    imports = [
      ../../../lib/features/browser.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/xdg-desktop.nix
    ];

    config.app = {
      name = "zen-browser";
      # Unconfigured base; customConfig swaps in the build with this host's
      # policies (modules.apps.zen-browser.browser.*) baked in.
      package = pkgs.zen-browser;
      # The package ships ONLY bin/zen-beta, and zen-beta.desktop runs `zen-beta` —
      # so that's the binary the systemd launcher must wrap.
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

      # modules.apps.zen-browser.browser.*: policies, extensions (uBlock Origin and
      # Vimium by default; op-broker's when it serves zen-browser), search engine, …
      # — see lib/browser-settings.nix. Policies only change settings and add
      # extensions; the .zen profile itself is untouched.
      customOptions =
        _:
        browserSettings.mkOptions {
          appName = "zen-browser";
          family = "gecko";
        };

      customConfig =
        { config, lib, ... }@args:
        lib.mkMerge [
          {
            modules.apps.zen-browser.sandbox.dedicatedUser = true;
            users.users."app-zen-browser".extraGroups = [
              "video"
              "audio"
            ];
            # Shared downloads under a per-app subdir: zen's ~/Downloads becomes jrt's
            # ~/Downloads/zen-browser (host-visible, on /large where impermanence already
            # persists Downloads; the launcher ACLs it + tmpfiles creates it). Keeps each
            # dedicated app's downloads separate instead of a shared pool.
            modules.apps.zen-browser.sandbox.sharedDownloads = true;
            # Zen upstream's one policy (its wrapper's): trust the system's CA
            # store through p11-kit. Kept, now that ours actually apply
            # (browser-settings.nix: the executable is copied, not linked).
            modules.apps.zen-browser.browser.policies.SecurityDevices."System Trust" =
              "${pkgs.p11-kit}/lib/pkcs11/p11-kit-trust.so";
          }
          (browserSettings.geckoConfig {
            appName = "zen-browser";
            basePackage = pkgs.zen-browser;
          } args)
        ];
    };
  }
)
