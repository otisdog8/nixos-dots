# Firefox web browser (ephemeral profile, discarded on every exit)

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
      name = "firefox";
      package = pkgs.firefox;
      packageName = "firefox";
      desktopFileName = "firefox.desktop";
      # gecko remote name: org.mozilla.<RemotingName=firefox>.<profile-instance>.
      # Lets the launcher forward URLs to a running window (and is the only
      # browser remote name this app may own — features/browser.nix).
      dbusName = "org.mozilla.firefox";

      # Dedicated-uid + ephemeral: no stash, and the app's $HOME isn't bound into
      # the sandbox — bwrap creates it on its own tmpfs root, so the profile is
      # discarded every time firefox exits. gecko goes native-Wayland via
      # MOZ_ENABLE_WAYLAND (gui.nix), with built-in portal ScreenCast — no --ozone
      # flag/wrapper needed.
      defaultBackend = "systemd";

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.firefox.sandbox.dedicatedUser = true;
          # Downloads land in jrt's ~/Downloads/firefox (host-visible, persisted).
          modules.apps.firefox.sandbox.sharedDownloads = true;
          users.users."app-firefox".extraGroups = [
            "video"
            "audio"
          ];
        };
    };
  }
)
