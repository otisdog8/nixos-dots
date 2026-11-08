# OBS Studio - screen recording/streaming — dedicated-uid sandbox, persistent config

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
    ];

    config.app = {
      name = "obs-studio";
      # Wrap OBS with plugins before sandboxing
      package = pkgs.wrapOBS.override { inherit (pkgs) obs-studio; } {
        plugins = with pkgs.obs-studio-plugins; [
          wlrobs
          obs-backgroundremoval
          obs-pipewire-audio-capture
        ];
      };
      packageName = "obs";
      # The browser source is CEF (Chromium), whose sandbox makes user
      # namespaces (lib/backends/bwrap-syscalls.nix).
      capabilities.nestedUserns = true;

      # Dedicated-uid, persistent: scenes + settings AND stream keys (.config/
      # obs-studio) run as app-obs-studio, hidden from a compromised jrt, kept across
      # reboots. Screen capture rides the PipeWire portal (cross-uid, like screenshare
      # elsewhere). Real cameras come on request (camera.nix); the virtual camera's
      # output, the v4l2loopback node (/dev/video1: enableVirtualCamera's video_nr=1),
      # is bound from the start (nixpakModules and video group below).
      defaultBackend = "systemd";
      storage = [
        {
          path = ".config/obs-studio";
          tier = "persist";
        }
      ];

      # Force Qt onto native Wayland (XWayland needs a cross-uid X-auth the dedicated
      # uid lacks). OBS then captures via wlrobs / the PipeWire portal on Wayland.
      nixpakModules = [
        (
          { ... }:
          {
            bubblewrap.env.QT_QPA_PLATFORM = "wayland";
            bubblewrap.bind.dev = [ "/dev/video1" ];
          }
        )
      ];

      customConfig =
        { config, lib, ... }:
        {
          # System-level v4l2loopback virtual-camera setup (our sandboxed package is
          # already in systemPackages, so package = null).
          programs.obs-studio = {
            enable = true;
            package = null;
          };
          # enableVirtualCamera's four settings, with v4l2loopback's output
          # cut back to the module: since kernel.dev ships System.map,
          # modules_install runs depmod into it, and its modules.* collide
          # with the kernel's in the module tree (nixpkgs#576406).
          boot = {
            kernelModules = [ "v4l2loopback" ];
            extraModulePackages = [
              (config.boot.kernelPackages.v4l2loopback.overrideAttrs (old: {
                postInstall = (old.postInstall or "") + ''
                  rm -f $out/lib/modules/*/modules.*
                '';
              }))
            ];
            extraModprobeConfig = ''
              options v4l2loopback devices=1 video_nr=1 card_label="OBS Cam" exclusive_caps=1
            '';
          };
          security.polkit.enable = true;

          modules.apps.obs-studio.sandbox.dedicatedUser = true;
          # video: the virtual camera's v4l2loopback node (/dev/video1, bound from
          # the start) is root:video 0660, and only the seat user gets a uaccess ACL.
          # The group also opens the other /dev/video* and /dev/dri/card* nodes, but
          # only those bound into the sandbox are there. No audio: no /dev/snd is
          # bound; sound goes through the broker's Pulse relay.
          users.users."app-obs-studio".extraGroups = [ "video" ];
        };
    };
  }
)
