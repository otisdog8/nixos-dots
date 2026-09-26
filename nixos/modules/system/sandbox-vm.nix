# VM sandbox tier: host-wide pieces shared by every app's microVM.
#
# The per-app parts (units, launcher, spec) come from lib/backends/vm.nix, which
# every mkApp app evaluates alongside its container backend; this module owns the
# single generic guest system they all boot (lib/vm/guest.nix), the graphics
# stack they share, and the runtime directory their units work in. The guest is
# only evaluated/built when some app actually uses its VM variant (mode = "vm" or
# modules.sandbox.variants.enable).
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.modules.sandbox.vm;
  user = config.users.users.${cfg.user};
  hasNvidia = lib.elem "nvidia" config.services.xserver.videoDrivers;

  nvgpu = import ../../../lib/vm/nvgpu.nix {
    inherit lib pkgs;
    src = inputs.virtio-nvgpu;
  };

  guest = inputs.nixpkgs.lib.nixosSystem {
    specialArgs.sbxHost = {
      inherit (cfg) user graphics;
      inherit (user) uid group;
      gid = config.users.groups.${user.group}.gid;
      locale = config.i18n.defaultLocale;
      timeZone = config.time.timeZone;
      stateVersion = config.system.stateVersion;
      # Same kernel as the host: nothing extra to build, and it has virtio-fs/vsock.
      kernelPackages = config.boot.kernelPackages;
      # virtio-nvgpu guests run NVIDIA's userspace at exactly the host driver's
      # release, so they take the host's own driver package.
      nvidiaPackage = if hasNvidia then config.hardware.nvidia.package else null;
      nvgpu = {
        inherit (nvgpu) wlGuest;
        kmod = nvgpu.kmod config.boot.kernelPackages;
      };
    };
    modules = [
      ../../../lib/vm/guest.nix
      # Reuse the host's package set (overlays included) instead of instantiating
      # nixpkgs a second time.
      { nixpkgs.pkgs = pkgs; }
    ];
  };
in
{
  options.modules.sandbox.vm = {
    user = lib.mkOption {
      type = lib.types.str;
      default = "jrt";
      description = "The host user whose session launches VM-sandboxed apps; mirrored (same name/uid) inside the guest.";
    };

    dns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "9.9.9.9"
        "149.112.112.112"
      ];
      description = ''
        Resolvers handed to VM guests (via passt's DHCP). Public ones: the host's
        own resolver listens on loopback, which the guest network can't reach.
      '';
    };

    graphics = lib.mkOption {
      type = lib.types.enum [
        "nvgpu"
        "cross-domain"
        "none"
      ];
      default = if hasNvidia then "nvgpu" else "cross-domain";
      defaultText = lib.literalMD ''"nvgpu" on NVIDIA hosts, else "cross-domain"'';
      description = ''
        How GUI apps in VMs reach the display (and, for nvgpu, the GPU):
        - nvgpu: virtio-nvgpu (lib/vm/nvgpu.nix). The guest runs NVIDIA's own
          driver against the host GPU, and its Wayland clients are clients of the
          host compositor with zero-copy GPU buffers. Apps with the gpu capability
          also get compute (CUDA). NVIDIA hosts only.
        - cross-domain: crosvm's virtio-gpu cross-domain Wayland; the guest renders
          in software. Any host.
        - none: no display; GUI apps start but show nothing.
        Either way the guest's windows reach Hyprland through a
        wp_security_context_v1 socket, like the container backends.
      '';
    };

    nvgpu = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      internal = true;
      default = nvgpu;
      description = "virtio-nvgpu's packages (lib/vm/nvgpu.nix).";
    };

    guest = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      internal = true;
      default = guest;
      description = "The evaluated generic guest NixOS system (lib/vm/guest.nix).";
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.graphics != "nvgpu" || hasNvidia;
        message = "modules.sandbox.vm.graphics = \"nvgpu\" needs the NVIDIA driver on the host (services.xserver.videoDrivers).";
      }
    ];

    # /run/sandbox-vm/<app>/<id>: per-launch keys, sockets and share mount points,
    # created and removed by each VM's root prep/cleanup (lib/backends/vm.nix).
    # Traversable, never listable or writable by unprivileged users.
    systemd.tmpfiles.rules = [ "d /run/sandbox-vm 0711 root root -" ];
  };
}
