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
    # qemu-libvirtd user, NOT root (upstream's default): membership in libvirtd
    # otherwise = effective root, since a client can launch a root QEMU with host
    # paths / block devices attached — which would also defeat the dedicated-uid
    # sandboxes' "protect jrt-compromise" goal (jrt is in libvirtd). With
    # runAsRoot = false a compromised guest/client is confined to that uid's DAC.
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
