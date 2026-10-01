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
      # Prism probes GameMode during startup. GameMode 1.8.2 sends pidfds and
      # aborts on a null pending D-Bus call when the transport cannot carry
      # them. The VM's vsock relay cannot carry fds, and guest PIDs cannot be
      # used by host GameMode. Disable the optional integration in our shared
      # package (both VM and container variants).
      package = pkgs.prismlauncher.override {
        gamemodeSupport = false;
        # In nixpkgs for Prism 11.1 this flag only changes the wrapper's library
        # path. The unwrapped application still probes GameMode unconditionally
        # on Linux, so explicitly suppress that probe and capability as well.
        prismlauncher-unwrapped = pkgs.prismlauncher-unwrapped.overrideAttrs (old: {
          postPatch = (old.postPatch or "") + ''
            substituteInPlace launcher/Application.cpp --replace-fail \
              'if (gamemode_query_status() >= 0)' \
              'if (false) // GameMode is unavailable in this sandbox package.'
          '';
        });
      };
      packageName = "prismlauncher";

      # No nesting here — clean tiers: config backed up, game installs large (not
      # backed up), cache disposable.
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

              # NOTE: /dev/input is deliberately NOT bound. Binding all evdev nodes
              # would hand the sandbox the same raw keyboard/mouse read surface
              # steam.nix documents as avoided (keylogging), and app-prismlauncher
              # isn't in the `input` group anyway so controllers over /dev/input
              # wouldn't have worked. Controller support, if needed later, should go
              # through a narrower path (a specific joystick node), not all of
              # /dev/input.
            };
          }
        )
      ];

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.prismlauncher.sandbox.dedicatedUser = true;
          modules.apps.prismlauncher.sandbox.vm.memory = lib.mkDefault 16384;
          modules.apps.prismlauncher.sandbox.vm.gpuMemoryMiB = lib.mkDefault 16384;
          modules.apps.prismlauncher.sandbox.vm.gpuMemoryProcessPercent = lib.mkDefault 90;
          # 8 vCPUs, pinned on 4 whole cores, with the other game settings.
          modules.apps.prismlauncher.sandbox.vm.vcpus = lib.mkDefault 8;
          modules.apps.prismlauncher.sandbox.vm.tuning = lib.mkDefault "game";
          # X11 forward for the Qt launcher + Java/LWJGL game (see
          # xwayland-forward.md; shares jrt's X server).
          modules.apps.prismlauncher.sandbox.x11Forward = true;
          users.users."app-prismlauncher".extraGroups = [
            "video"
            "audio"
          ];
        };
    };
  }
)
