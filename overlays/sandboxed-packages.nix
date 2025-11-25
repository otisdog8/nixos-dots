{ inputs, ... }:
final: prev:
let
  mkNixPak = inputs.nixpak.lib.nixpak {
    inherit (final) lib;
    pkgs = final;
  };

  sandboxed-prismlauncher = mkNixPak {
    config = { sloth, ... }: {
      # The application to isolate
      app.package = prev.prismlauncher;

      # Path to the executable
      app.binPath = "bin/prismlauncher";
      
      # Enable SSL certificates
      etc.sslCertificates.enable = true;
      
      # Enable fonts
      fonts.enable = true;
      
      # Enable locale support
      locale.enable = true;

      # Enable dbus for desktop integration
      dbus.enable = true;

      # DBus policies for desktop services
      dbus.policies = {
        "org.freedesktop.DBus" = "talk";
        "ca.desrt.dconf" = "talk";
        "org.freedesktop.portal.*" = "talk";
        "org.freedesktop.Notifications" = "talk";
        "org.kde.StatusNotifierWatcher" = "talk";
        "com.canonical.AppMenu.Registrar" = "talk";
        "com.canonical.Unity.LauncherEntry" = "talk";
        "org.kde.kwalletd5" = "talk";
        "org.kde.kwalletd6" = "talk";
      };

      # Flatpak app ID
      flatpak.appId = "org.prismlauncher.PrismLauncher";

      bubblewrap = {
        # Enable network for downloading game files, mods, and multiplayer
        network = true;
        
        # Enable API VFS for device and process access
        apivfs = {
          dev = true;
          proc = true;
        };
        
        # Enable sockets for GUI and audio
        sockets = {
          wayland = true;  # For Wayland support
          pulse = true;  # For audio
          pipewire = true;  # For PipeWire audio
        };

        # Bind paths for PrismLauncher
        bind.rw = [
          # PrismLauncher data directory
          (sloth.concat' sloth.homeDir "/.local/share/PrismLauncher")
          
          # Config directory
          (sloth.concat' sloth.homeDir "/.config/PrismLauncher")
          
          # Cache directory
          (sloth.concat' sloth.homeDir "/.cache/PrismLauncher")
          
          # Default Minecraft instances location
          (sloth.concat' sloth.homeDir "/.local/share/PrismLauncher/instances")
          
          # Alternative Games folder if user has one
          (sloth.concat' sloth.homeDir "/Games")
          
          # XDG runtime directory for Wayland/X11
          (sloth.env "XDG_RUNTIME_DIR")
          
          # Temp directory for downloads
          "/tmp"
          
          # Sysfs for GPU detection (read-write)
          "/sys/dev/char"
          "/sys/devices"
        ];

        bind.ro = [
          # X11 socket for OpenGL/GLX
          "/tmp/.X11-unix"
          
          # Read-only access to system themes
          "/usr/share/icons"
          "/usr/share/fonts"
          "/run/current-system/sw/share/icons"
          "/run/current-system/sw/share/fonts"
          
          
          # System locale
          "/usr/share/locale"
          "/run/current-system/sw/share/locale"
          
          # System cursors
          "/usr/share/cursors"

          # System binaries (for Java detection)
          "/run/current-system/sw/bin"
          "/etc/profiles/per-user"
          "/nix/var/nix/profiles"
          
          # GPU/OpenGL driver paths
          "/run/opengl-driver"
          "/run/opengl-driver-32"
          "/etc/egl"
          "/etc/vulkan"
          "/etc/OpenCL"
          "/usr/share/glvnd"
          "/usr/share/vulkan"
          "/run/current-system/sw/share/glvnd"
          "/run/current-system/sw/share/vulkan"
          
          # Additional GL/EGL config
          "/etc/glvnd"
          "/usr/share/egl"
          
          # DRI config
          "/etc/drirc"
          "/usr/share/drirc.d"
        ];
        
        bind.dev = [
          # GPU devices
          "/dev/dri"
          "/dev/nvidia0"
          "/dev/nvidiactl"
          "/dev/nvidia-modeset"
          "/dev/nvidia-uvm"
          "/dev/nvidia-uvm-tools"
          
          # Input devices (for controllers)
          "/dev/input"
          
          # Sound devices
          "/dev/snd"
        ];

        # Environment variables
        env = {
          # Preserve display variables
          DISPLAY = sloth.env "DISPLAY";
          WAYLAND_DISPLAY = sloth.env "WAYLAND_DISPLAY";
          
          # Qt/GTK theming
          QT_QPA_PLATFORMTHEME = sloth.env "QT_QPA_PLATFORMTHEME";
          
          # GPU optimizations
          __GL_THREADED_OPTIMIZATIONS = "1";
          mesa_glthread = "true";
          
          # Locale
          LANG = sloth.env "LANG";
        };
      };
    };
  };
in
{
  prismlauncher-sandboxed = sandboxed-prismlauncher.config.env;
}
