# PrismLauncher - Minecraft launcher

(import ../../../lib/apps.nix).mkApp (
  {
    config,
    lib,
    pkgs,
    ...
  }:
  {
    imports = [
      ../../../lib/features/gui.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/network.nix
      ../../../lib/features/audio.nix
      ../../../lib/features/xdg-desktop.nix
    ];

    config.app = {
      name = "prismlauncher";
      package = pkgs.prismlauncher;
      packageName = "prismlauncher";

      # v2 unified storage (replaces persistence.user.* + impermanence). No nesting
      # here — clean tiers: config backed up, game installs large (not backed up),
      # cache disposable.
      #
      # Dedicated-uid + XWayland forward. PrismLauncher (Qt) and the Minecraft it
      # launches (Java/LWJGL) both use X11; a dedicated uid can't auth to jrt's XWayland
      # on its own, so x11Forward (customConfig below) grants it via the launcher's
      # xhost. Config/instances run as app-prismlauncher, hidden from jrt.
      defaultBackend = "systemd";
      storage = [
        {
          path = ".config/PrismLauncher";
          tier = "persist";
        }
        {
          path = ".local/share/PrismLauncher";
          tier = "large";
        }
        {
          path = ".cache/PrismLauncher";
          tier = "cache";
        }
      ];

      # Additional sandbox configuration
      nixpakModules = [
        (
          { lib, sloth, ... }:
          {
            # Flatpak app ID
            flatpak.appId = "org.prismlauncher.PrismLauncher";

            bubblewrap.bind = {
              rw = [
                # Sysfs for GPU detection
                "/sys/dev/char"
                "/sys/devices"
              ];

              ro = [
                # System binaries (for Java detection)
                "/run/current-system/sw/bin"
                "/etc/profiles/per-user"
                "/nix/var/nix/profiles"
              ];

              dev = [
                # Input devices (for controllers)
                "/dev/input"
              ];
            };
          }
        )
      ];

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.prismlauncher.sandbox.dedicatedUser = true;
          # X11 forward for the Qt launcher + Java/LWJGL game (POC — see
          # xwayland-forward-POC.md; shares jrt's X server).
          modules.apps.prismlauncher.sandbox.x11Forward = true;
          users.users."app-prismlauncher".extraGroups = [
            "video"
            "audio"
            "input" # /dev/input is root:input 0660 — needed to read controllers
          ];
        };
    };
  }
)
