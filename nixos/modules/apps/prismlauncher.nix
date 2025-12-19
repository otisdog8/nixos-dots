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

      # Persistence configuration
      persistence.user = {
        # PrismLauncher config
        persist = [
          ".config/PrismLauncher"
        ];

        # Game installations
        large = [
          ".local/share/PrismLauncher"
        ];

        # Cache
        cache = [
          ".cache/PrismLauncher"
        ];
      };

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
