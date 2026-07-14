# Virtualization configuration - libvirt, virt-manager, QEMU/KVM
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.system.virt;
in
{
  options.modules.system.virt = {
    enable = lib.mkEnableOption "virtualization support (libvirt, QEMU, KVM)";
  };

  config = lib.mkIf cfg.enable {
    # Virtualization packages
    environment.systemPackages = with pkgs; [
      qemu
      qemu_kvm
      libvirt
      bridge-utils
      virt-manager
    ];

    # Enable libvirtd daemon. Run guest QEMU processes as the unprivileged
    # qemu-libvirtd user, NOT root (upstream's default) — this contains the GUEST
    # process (a VM escape lands as qemu-libvirtd, DAC-confined, not root).
    #
    # It does NOT constrain a management CLIENT: a system-mode read/write libvirt
    # connection is documented by upstream as typically equivalent to a root shell
    # (define a domain with an arbitrary host disk / <qemu:commandline> and start
    # it), and the libvirtd group grants exactly that. So runAsRoot = false is not a
    # defense against a compromised libvirtd-group member. That's why jrt is NOT in
    # the libvirtd group (see nixos/default.nix): manage system VMs with sudo, or
    # use a rootless qemu:///session connection.
    virtualisation.libvirtd = {
      enable = true;
      qemu.runAsRoot = false;
    };

    # Enable virt-manager
    programs.virt-manager.enable = true;

    # Persistence for virtualization
    environment.persistence."/large" = {
      directories = [
        "/var/lib/libvirt"
      ];
    };
  };
}
