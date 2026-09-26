# Guest display and GPU for the sandbox VMs (modules.sandbox.vm.graphics).
#
# Both modes end in one Wayland socket in the guest that the app's clients use
# (lib/backends/vm.nix sets WAYLAND_DISPLAY); its host end is a
# wp_security_context_v1 socket on Hyprland, like the container backends'.
#   - nvgpu: the virtio-nvgpu guest module registers the host GPU (NVIDIA's own
#     userspace drives it, at the host driver's exact release) and /dev/nvgpu-wl,
#     which nvgpu-wl-guest turns into /run/sbx/wl/wayland-0. GPU buffers reach the
#     compositor without a copy.
#   - cross-domain: wayland-proxy-virtwl over crosvm's virtio-gpu cross-domain
#     context serves $XDG_RUNTIME_DIR/wayland-0; the guest renders in software.
# X11 apps get xwayland-satellite on that socket (started by sbx-setup when the
# app's spec says x11).
{
  lib,
  pkgs,
  sbxHost,
  ...
}:
let
  mode = sbxHost.graphics;
  user = sbxHost.user;
  runtimeDir = "/run/user/${toString sbxHost.uid}";
  nv = sbxHost.nvidiaPackage;

  # The guest's Wayland socket, as a WAYLAND_DISPLAY value (relative names are
  # under $XDG_RUNTIME_DIR). Mirrored in lib/backends/vm.nix.
  waylandDisplay = if mode == "nvgpu" then "/run/sbx/wl/wayland-0" else "wayland-0";

  # NVIDIA's EGL external platforms, as the host's nvidia module combines them.
  eglPlatforms = pkgs.symlinkJoin {
    name = "nvidia-egl-external-platforms";
    paths = with pkgs; [
      egl-wayland
      egl-gbm
      egl-wayland2
      egl-x11
    ];
  };
in
lib.mkMerge [
  (lib.mkIf (mode != "none") {
    hardware.graphics.enable = true;
    users.users.${user}.extraGroups = [
      "video"
      "render"
    ];
    # The user's runtime dir: sessions come in over SSH without PAM/logind, so
    # nothing else creates it.
    systemd.tmpfiles.rules = [ "d ${runtimeDir} 0700 ${user} ${sbxHost.group} -" ];

    systemd.services.sbx-xwayland = {
      description = "Xwayland for the app's X11 clients";
      requires = [ "sbx-wayland.service" ];
      after = [ "sbx-wayland.service" ];
      path = [ pkgs.xwayland ];
      environment = {
        XDG_RUNTIME_DIR = runtimeDir;
        WAYLAND_DISPLAY = waylandDisplay;
      };
      serviceConfig = {
        User = user;
        ExecStart = "${pkgs.xwayland-satellite}/bin/xwayland-satellite :0";
        Restart = "on-failure";
        RestartSec = 1;
      };
    };
  })

  (lib.mkIf (mode == "nvgpu") {
    boot.extraModulePackages = [ sbxHost.nvgpu.kmod ];
    boot.kernelModules = [ "virtio_gpu_nv" ];
    boot.blacklistedKernelModules = [
      # virtio-nvgpu uses virtio device ID 45, which Linux also assigns to
      # virtio-spi; keep that driver from claiming the GPU.
      "spi_virtio"
      # The host driver's modules never belong in the guest.
      "nvidia"
      "nvidia_drm"
      "nvidia_modeset"
      "nvidia_uvm"
      "nouveau"
    ];

    hardware.graphics.extraPackages = [
      nv.out
      eglPlatforms
    ];
    environment.etc."egl/egl_external_platform.d".source =
      "/run/opengl-driver/share/egl/egl_external_platform.d/";
    environment.systemPackages = [ nv.bin ]; # nvidia-smi

    # /dev/nvgpu-wl: every open is a client of the host compositor, so only the
    # proxy daemon's account gets it (virtio-nvgpu's scripts/70-nvgpu-wl.rules).
    users.groups.nvgpu-wl = { };
    users.users.nvgpu-wl = {
      isSystemUser = true;
      group = "nvgpu-wl";
    };
    services.udev.extraRules = ''
      SUBSYSTEM=="misc", KERNEL=="nvgpu-wl*", GROUP="nvgpu-wl", MODE="0660"
    '';
    systemd.tmpfiles.rules = [ "d /run/sbx/wl 0755 nvgpu-wl nvgpu-wl -" ];

    systemd.services.sbx-wayland = {
      description = "Wayland proxy to the host compositor (virtio-nvgpu)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "systemd-modules-load.service"
        "systemd-udev-trigger.service"
        "systemd-tmpfiles-setup.service"
      ];
      serviceConfig = {
        ExecStart = "${sbxHost.nvgpu.wlGuest}/bin/nvgpu-wl-guest --socket ${waylandDisplay}";
        User = "nvgpu-wl";
        Group = "nvgpu-wl";
        # The socket must be connectable by the app's user.
        UMask = "0011";
        Restart = "on-failure";
        RestartSec = 1;
      };
    };
  })

  (lib.mkIf (mode == "cross-domain") {
    systemd.services.sbx-wayland = {
      description = "Wayland proxy to the host compositor (virtio-gpu cross-domain)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "systemd-udev-trigger.service"
        "systemd-tmpfiles-setup.service"
      ];
      environment.XDG_RUNTIME_DIR = runtimeDir;
      serviceConfig = {
        ExecStart = "${pkgs.wayland-proxy-virtwl}/bin/wayland-proxy-virtwl --virtio-gpu --wayland-display ${waylandDisplay}";
        User = user;
        SupplementaryGroups = [
          "video"
          "render"
        ];
        Restart = "on-failure";
        RestartSec = 1;
      };
    };
  })
]
