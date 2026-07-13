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
      # DEDICATED-UID EXPERIMENT (deliberately NOT applied): PrismLauncher is Qt, but it
      # launches Minecraft via Java/LWJGL which commonly needs XWayland — a dedicated
      # uid can't auth to the X server (zoom's failure mode). Same caveat as lunar: try
      # defaultBackend="systemd" + dedicatedUser + QT_QPA_PLATFORM=wayland, but VALIDATE
      # a launched instance's game window actually renders before relying on it.
      defaultBackend = "nixpak";
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
    };
  }
)
