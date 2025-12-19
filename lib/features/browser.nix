# Web browser feature
{ config, lib, ... }:

{
  # Browsers are GUI apps with network
  imports = [
    ./gui.nix
    ./network.nix
  ];

  config.app = {
    # Browser-specific nixpak configuration
    nixpakModules = [
      (
        {
          config,
          lib,
          pkgs,
          sloth,
          ...
        }:
        {
          # Browsers need access to downloads
          bubblewrap.bind.rw = [
            (sloth.concat' sloth.homeDir "/Downloads")
          ];

          # DBus policies for browser to advertise its remote control service
          # This allows xdg-open from other apps to connect to running browser
          dbus.policies = {
            # Firefox-based browsers need to own their service
            "org.mozilla.firefox.*" = "own";
            "org.mozilla.Firefox.*" = "own";
            "org.mozilla.zen.*" = "own";
            # Chromium-based browsers
            "org.chromium.Chromium.*" = "own";
            "com.brave.Browser.*" = "own";
          };
        }
      )
    ];
  };
}
