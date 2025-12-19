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

    # Enable libvirtd daemon
    virtualisation.libvirtd.enable = true;

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
