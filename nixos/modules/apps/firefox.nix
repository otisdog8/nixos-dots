# Firefox Developer Edition (ephemeral profile, discarded on every exit)
#
# Developer Edition rather than release: release Firefox refuses unsigned add-ons
# with no override, and op-broker's extension (docs/op-broker.md) is an unsigned
# XPI from the store. Developer Edition (nixpkgs builds it without
# MOZ_REQUIRE_SIGNING) honours xpinstall.signatures.required = false, which
# browser.allowUnsignedExtensions locks when op-broker serves this app. It tracks
# the Firefox beta channel. The app keeps its name (modules.apps.firefox, uid
# app-firefox, ~/Downloads/firefox); the command (firefox-devedition), desktop
# entry and D-Bus remote name are Developer Edition's.
#
# Profile: Developer Edition creates its own profile (dev-edition-default) where
# release used default-release, so it would not pick up a release profile. Here
# there is none to pick up: this app has no storage entries, the profile lives in
# the sandbox's tmpfs home (container) or the guest's tmpfs root (VM) and is
# discarded on every exit, so every start is a fresh profile with either edition.

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
      name = "firefox";
      # Unconfigured base; customConfig swaps in the build with this host's
      # policies (modules.apps.firefox.browser.*) baked in.
      package = pkgs.firefox-devedition;
      # The wrapper ships only bin/firefox-devedition, and firefox-devedition.desktop
      # runs `firefox-devedition`: that's the binary the systemd launcher wraps.
      packageName = "firefox-devedition";
      desktopFileName = "firefox-devedition.desktop";
      # gecko remote name: org.mozilla.<RemotingName>.<profile-instance>, the
      # RemotingName (firefox-devedition, see application.ini) made D-Bus-safe
      # ('-' → '_'). Lets the launcher forward URLs to a running window (and is
      # the only browser remote name this app may own — features/browser.nix).
      # Verify with `busctl --user list | grep -i mozilla` if link-forwarding misses.
      dbusName = "org.mozilla.firefox_devedition";

      # Dedicated-uid + ephemeral: no stash, and the app's $HOME isn't bound into
      # the sandbox — bwrap creates it on its own tmpfs root, so the profile is
      # discarded every time firefox exits. gecko goes native-Wayland via
      # MOZ_ENABLE_WAYLAND (gui.nix), with built-in portal ScreenCast — no --ozone
      # flag/wrapper needed.
      defaultBackend = "systemd";

      # modules.apps.firefox.browser.*: policies, extensions (uBlock Origin and
      # Vimium by default; op-broker's when it serves firefox), search engine, … —
      # see lib/browser-settings.nix.
      customOptions =
        _:
        browserSettings.mkOptions {
          appName = "firefox";
          family = "gecko";
        };

      customConfig =
        { config, lib, ... }@args:
        lib.mkMerge [
          {
            modules.apps.firefox.sandbox.dedicatedUser = true;
            # Downloads land in jrt's ~/Downloads/firefox (host-visible, persisted).
            modules.apps.firefox.sandbox.sharedDownloads = true;
            users.users."app-firefox".extraGroups = [
              "video"
              "audio"
            ];
          }
          (browserSettings.geckoConfig {
            appName = "firefox";
            basePackage = pkgs.firefox-devedition;
          } args)
        ];
    };
  }
)
