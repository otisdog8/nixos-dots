# Zoom video conferencing — dedicated-uid sandbox, persistent config

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
      ../../../lib/features/microphone.nix
      ../../../lib/features/camera.nix
      ../../../lib/features/screen-capture.nix
      ../../../lib/features/xdg-desktop.nix
      ../../../lib/features/system-tray.nix
    ];

    config.app = {
      name = "zoom";
      package = pkgs.zoom-us;
      packageName = "zoom";
      # QtWebEngine (Chromium): its sandbox makes user namespaces
      # (lib/backends/bwrap-syscalls.nix).
      capabilities.nestedUserns = true;

      # Dedicated-uid, persistent: login/settings (.zoom + .config) run as app-zoom —
      # hidden from a compromised jrt — and kept across reboots. Screen share rides
      # the PipeWire portal (works cross-uid already).
      defaultBackend = "systemd";
      storage = [
        {
          path = ".zoom";
          tier = "persist";
        }
        # zoom.conf / zoomus.conf live here. Persist the DIRECTORY, not the two
        # files: Qt's QSettings saves via write-temp-then-rename(), and renaming
        # over a single-file bind mount fails (EBUSY), so settings never stuck.
        # The home belongs to app-zoom alone, so the whole .config is safe to keep.
        {
          path = ".config";
          tier = "persist";
        }
      ];

      # Drive Qt onto XCB (not native Wayland): zoom's bundled Qt6 segfaulted a child
      # on native Wayland. In the container, X is jrt's XWayland through the
      # x11Forward grant (customConfig below; the launcher sets up socket and auth);
      # in the VM, the guest's own X server (sandbox.vm.x11). app.environment, not a
      # raw nixpak module, so the VM gets it too.
      environment.QT_QPA_PLATFORM = "xcb";

      customConfig =
        { config, lib, ... }:
        {
          modules.apps.zoom.sandbox.dedicatedUser = true;
          # Its VM by default where VMs get the GPU (virtio-nvgpu: the NVIDIA
          # desktops), so the plain command and its file/link handlers start the
          # VM, with an X server of its own (xwayland-satellite in the guest),
          # not the container on jrt's XWayland. Elsewhere (constitution: Intel,
          # where a VM would render in software; liveusb: unknown hardware,
          # hosts/liveusb) the container stays the default. In the VM a camera comes on
          # approval, passed through over USB (camera.nix). The container is
          # still there as "zoom (container)" / zoom-container, and it still
          # shares jrt's X server through x11Forward (below).
          modules.apps.zoom.sandbox.mode = lib.mkIf config.modules.sandbox.vm.nvgpuAvailable (
            lib.mkDefault "vm"
          );
          modules.apps.zoom.sandbox.vm.x11 = lib.mkDefault true;
          modules.apps.zoom.sandbox.x11Forward = true;
        };
    };
  }
)
