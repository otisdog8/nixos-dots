# Open links in default browser feature
# Allows apps to open URLs in an existing browser instance via DBus
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    ({ lib, ... }: {
      # Enable DBus remote control for Firefox-based browsers
      # This allows apps to open URLs in running browser instance via DBus
      # instead of X11 properties (which don't work on Wayland)
      bubblewrap.env.MOZ_DBUS_REMOTE = "1";

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
    })
  ];
}
