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

        # When Electron/Chromium shells out to `xdg-open` (its fallback when it doesn't
        # use the portal — see the .flatpak-info bind below), a stock xdg-open can't
        # reach the host browser from inside the sandbox. So build a PATH where
        # flatpak-xdg-utils comes FIRST: its xdg-open D-Bus-calls
        # org.freedesktop.portal.OpenURI (talk-allowed by xdg.nix, reachable over the
        # session-bus bridge) → host default handler → running browser. Then real
        # xdg-utils for the other xdg-* tools flatpak-xdg-utils lacks — notably
        # xdg-settings, which some Electron apps (tetrio) shell out to at startup and
        # CRASH on if it's missing. Then the inherited PATH. bindEntireStore=true makes
        # both closures available.
        bubblewrap.env.PATH = sloth.concat [
          "${pkgs.flatpak-xdg-utils}/bin"
          ":"
          "${pkgs.xdg-utils}/bin"
          ":"
          (sloth.envOr "PATH" "/run/current-system/sw/bin")
        ];

        # Binding nixpak's generated .flatpak-info lets Electron/Chromium detect the
        # sandbox and PREFER the OpenURI portal for shell.openExternal (reaching the host
        # default handler → running browser); without it they'd fall back to xdg-open
        # (covered by the PATH above). This is the app's OWN self-detection — same
        # app-id as, but separate from, the doc-portal bridge identity.
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
