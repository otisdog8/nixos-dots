# Open links in default browser feature
# Allows apps to open URLs in an existing browser instance via DBus
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    (
      {
        config,
        lib,
        pkgs,
        sloth,
        ...
      }:
      {
        # Enable DBus remote control for Firefox-based browsers
        # This allows apps to open URLs in running browser instance via DBus
        # instead of X11 properties (which don't work on Wayland)
        bubblewrap.env.MOZ_DBUS_REMOTE = "1";

        # Chromium/Electron's shell.openExternal shells out to `xdg-open` (Chromium
        # only routes FILE dialogs through the portal, not URL opens), and a stock
        # xdg-open can't reach the host browser from inside the sandbox — hence the
        # "failed to execvp: xdg-open" (it isn't even on PATH). flatpak-xdg-utils'
        # xdg-open instead D-Bus-calls org.freedesktop.portal.OpenURI (talk-allowed
        # by xdg.nix, reachable over the session-bus bridge) → host default handler
        # (the zen launcher, as jrt) → running browser. Prepend it so it shadows any
        # real xdg-open; bindEntireStore=true already makes its closure available.
        bubblewrap.env.PATH = sloth.concat [
          "${pkgs.flatpak-xdg-utils}/bin"
          ":"
          (sloth.envOr "PATH" "/run/current-system/sw/bin")
        ];

        # Chromium/electron route link clicks (shell.openExternal) through the OpenURI
        # portal — which reaches the HOST default handler → our sandbox launcher's URL
        # forwarding — only when they detect a sandbox via /.flatpak-info. Without it
        # they spawn xdg-open, which can't reach the host browser from inside the
        # sandbox ("failed to execvp: xdg-open"). Bind nixpak's generated .flatpak-info
        # (the app's OWN self-detection; separate from the doc-portal bridge identity,
        # same app-id).
        bubblewrap.bind.ro = [
          [
            "${config.flatpak.infoFile}"
            "/.flatpak-info"
          ]
        ];

        # DBus policies for browser remote control
        # Use mkDefault so browsers can override with "own"
        dbus.policies = {
          # Firefox uses org.mozilla.firefox.<profile> service name
          "org.mozilla.firefox.*" = lib.mkDefault "talk";
          "org.mozilla.Firefox.*" = lib.mkDefault "talk";
          # Zen browser uses org.mozilla.zen.<profile>
          "org.mozilla.zen.*" = lib.mkDefault "talk";
          # Chromium-based browsers
          "org.chromium.Chromium.*" = lib.mkDefault "talk";
          "com.brave.Browser.*" = lib.mkDefault "talk";
        };
      }
    )
  ];
}
