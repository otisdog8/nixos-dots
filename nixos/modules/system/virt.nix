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

    nestedVirtualization = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Let KVM guests run their own hypervisor (kvm_amd/kvm_intel nested=1).
        Off by default: nested virtualization is a large, historically escape-prone
        part of KVM (it's how several 2026 guest-to-host escapes were reached),
        and nothing here needs it. The sandbox VMs never do; turn it on only for a
        guest that must run VMs itself (WSL2, Android emulators, VM-in-VM tests).
      '';
    };
  };

  config = lib.mkMerge [
    {
      # Applies whether or not libvirt is enabled: the KVM modules load anyway
      # (the sandbox VMs use them).
      boot.extraModprobeConfig =
        let
          n = if cfg.nestedVirtualization then "1" else "0";
        in
        ''
          options kvm_amd nested=${n}
          options kvm_intel nested=${n}
        '';
    }
    (lib.mkIf cfg.enable {
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
    })
  ];
}
