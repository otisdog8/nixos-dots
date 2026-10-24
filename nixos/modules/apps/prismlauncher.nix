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
      #
      # NVIDIA's threaded optimizations (on by default for Minecraft) off,
      # unless an instance sets the variable itself: the GL thread hands every
      # frame's work to a driver thread and spins until it is done. In the VM,
      # where that thread's driver calls cross to the host, Better MC without
      # shaders went from ~485 to ~760 fps without it; the container (~1150) and
      # shader-bound frames (~142 fps either way) are unaffected.
      package =
        (pkgs.prismlauncher.override {
          gamemodeSupport = false;
          # MangoHud on the launcher's PATH, so an instance's wrapper command can
          # be `mangohud` (frame-time overlay and logs) in the container and the
          # VM. Its launcher is a `#!/bin/sh` script, and the container has no
          # /bin/sh: the copy here names the store's shell.
          additionalPrograms = [
            (pkgs.runCommand "mangohud-${pkgs.mangohud.version}-launcher" { } ''
              mkdir -p $out/bin
              substitute ${pkgs.mangohud}/bin/mangohud $out/bin/mangohud \
                --replace-fail '#!/bin/sh' '#!${pkgs.runtimeShell}'
              chmod +x $out/bin/mangohud
            '')
          ];
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
        }).overrideAttrs
          (old: {
            qtWrapperArgs = old.qtWrapperArgs ++ [ "--set-default __GL_THREADED_OPTIMIZATIONS 0" ];
          });
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
          # Game VM sizing, as steam.nix.
          modules.apps.prismlauncher.sandbox.vm.memory = lib.mkDefault 32768;
          modules.apps.prismlauncher.sandbox.vm.gpuMemoryMiB = lib.mkDefault 24576;
          modules.apps.prismlauncher.sandbox.vm.gpuMemoryProcessPercent = lib.mkDefault 90;
          modules.apps.prismlauncher.sandbox.vm.vcpus = lib.mkDefault 12;
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
