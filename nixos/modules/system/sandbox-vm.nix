# VM sandbox tier: host-wide pieces shared by every app's microVM.
#
# The per-app parts (units, launcher, spec) come from lib/backends/vm.nix, which
# every mkApp app evaluates alongside its container backend; this module owns the
# single generic guest system they all boot (lib/vm/guest.nix) and the runtime
# directory their units work in. The guest is only evaluated/built when some app
# actually uses its VM variant (mode = "vm" or modules.sandbox.variants.enable).
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

  guest = inputs.nixpkgs.lib.nixosSystem {
    specialArgs.sbxHost = {
      inherit (cfg) user;
      inherit (user) uid group;
      gid = config.users.groups.${user.group}.gid;
      locale = config.i18n.defaultLocale;
      timeZone = config.time.timeZone;
      stateVersion = config.system.stateVersion;
      # Same kernel as the host: nothing extra to build, and it has virtio-fs/vsock.
      kernelPackages = config.boot.kernelPackages;
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

    guest = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      internal = true;
      default = guest;
      description = "The evaluated generic guest NixOS system (lib/vm/guest.nix).";
    };
  };

  config = {
    # /run/sandbox-vm/<app>/<id>: per-launch keys, sockets and share mount points,
    # created and removed by each VM's root prep/cleanup (lib/backends/vm.nix).
    # Traversable, never listable or writable by unprivileged users.
    systemd.tmpfiles.rules = [ "d /run/sandbox-vm 0711 root root -" ];
  };
}
