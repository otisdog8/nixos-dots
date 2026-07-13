# Firefox web browser (tmpfs-only, all data cleared on reboot)

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
      ../../../lib/features/tmpfs-homedir.nix
      ../../../lib/features/onepassword.nix
    ];

    config.app = {
      name = "firefox";
      package = pkgs.firefox;
      packageName = "firefox";
      desktopFileName = "firefox.desktop";

      # Dedicated-uid + ephemeral (tmpfs home, no stash). gecko goes native-Wayland
      # via MOZ_ENABLE_WAYLAND (gui.nix), with built-in portal ScreenCast — no
      # --ozone flag/wrapper needed.
      defaultBackend = "systemd";

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.firefox.sandbox.dedicatedUser = true;
          users.users."app-firefox".extraGroups = [
            "video"
            "audio"
          ];
        };
    };
  }
)
