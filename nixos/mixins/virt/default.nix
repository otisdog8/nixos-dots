
{ inputs, lib, pkgs, ... }:
{
  # Ensure the system installs the desired virtualization packages
  environment.systemPackages = with pkgs; [
    qemu
    qemu_kvm
    libvirt
    bridge-utils
    virt-manager
  ];

  virtualisation.libvirtd.enable = true;
  programs.virt-manager.enable = true;

}
