# arquitens, the machine, as a hypervisor (modules/system/node-vm.nix): it
# runs the k3s node "arquitens" as a VM (hosts/arquitens-node) and nothing
# else. The node took this machine's identity with it — its ssh host keys,
# Tailscale state (100.126.30.73), machine-id, hostd pairing and the LAN NIC's
# MAC, so its DHCP lease — and this machine starts over as arquitens-hv.
# Conversion and rollback: docs/node-vms.md.
#
# Root here is every VM on the machine, so nothing an agent reaches runs
# here: no hostd (forced off below), no k3s, no libvirt, no agent VM.
{
  inputs,
  lib,
  outputs,
  ...
}:
{
  networking.hostName = "arquitens-hv";
  time.timeZone = "America/Los_Angeles";

  boot.supportedFilesystems = [ "btrfs" ];

  imports = [
    inputs.disko.nixosModules.disko
    ./disks.nix

    inputs.nixos-hardware.nixosModules.common-cpu-amd
    inputs.nixos-hardware.nixosModules.common-gpu-amd
    inputs.nixos-hardware.nixosModules.common-pc
    inputs.nixos-hardware.nixosModules.common-pc-ssd

    ../../modules/desktop/full
    ../../modules/system/hardware/amd.nix
  ];

  modules = {
    desktop.full.enable = false;
    system.hardware.amd.enable = true;

    # No libvirt: the VMs are node-vm units, and libvirtd's socket would be a
    # second way to define one with any disk on the machine.
    system.virt.enable = false;
    system.developer-tools.enable = false;

    # The Micron 5300's write-cache udev rule only: the disk itself is the
    # VM's, which unlocks it (hosts/arquitens-node).
    system.cephOsdDisk.enable = true;

    system.zswap.enable = true;

    system.hardening = {
      enable = true;
      profile = "server";
      blacklistAfAlg = true;
    };

    # The same root LUKS as the bare-metal node, so the same PCR 15.
    system.pcr-verification = {
      enable = true;
      deviceName = "cryptarquitens";
      expectedPcr15 = "ea66c8b7ae01bb530fb964abebd4ec43441229e3beeb1941f5a7a157743ddc19";
    };

    # To carrack's node: never to this machine's own node VM, which it
    # can't reach over the LAN (macvtap doesn't hairpin, node-vm.nix).
    system.netconsole = {
      enable = true;
      collectorIp = "10.0.0.11"; # carrack
      collectorMac = "00:24:27:88:a9:bc";
    };

    # The node VMs' unit, proven on a throwaway guest (node-vm.nix).
    system.nodeVmSmoke = {
      enable = true;
      parentInterface = "enp4s0f4u1";
    };

    system.nodeVms.node = {
      guest = outputs.nixosConfigurations.arquitens-node;
      # 64 GB machine: ~4 GiB for itself, room for the sensitive cluster's VM
      # later (docs/node-vms.md).
      memoryMiB = 46 * 1024;
      vcpus = 14;
      # The USB dongle's own MAC: the node keeps 10.0.0.10 and netconsole's
      # "arquitens" entry (whose device is the MAC's enx altname).
      mac = "00:24:27:88:a9:c4";
      parentInterface = "enp4s0f4u1";
      disks = [
        {
          device = "/dev/vg/node";
          serial = "node-root";
        }
        {
          device = "/dev/vg/node-swap";
          serial = "node-swap";
        }
        {
          device = "/dev/vg/data";
          serial = "node-data";
        }
        {
          device = "/dev/disk/by-id/ata-MTFDDAK1T9TDS_221436ADEA78";
          serial = "node-ceph";
        }
      ];
    };
  };

  # The dongle gives its MAC to the VM and takes a locally administered one
  # (a new DHCP lease). Matched by its permanent MAC; the naming policies are
  # the default link's, which this file replaces for the dongle, so it stays
  # enp4s0f4u1 (the VM's parentInterface).
  systemd.network.links."10-lan" = {
    matchConfig.PermanentMACAddress = "00:24:27:88:a9:c4";
    linkConfig = {
      MACAddress = "02:24:27:88:a9:c4";
      NamePolicy = "keep kernel database onboard slot path";
      AlternativeNamesPolicy = "database onboard slot path mac";
    };
  };

  # First Tailscale login as arquitens-hv: a one-off auth key, put there by
  # hand at the conversion and deleted after (docs/node-vms.md).
  services.tailscale.authKeyFile = "/persist/tailscale-hv.authkey";

  services.agent-auth-hostd.enable = lib.mkForce false;

  # Unlike the nodes (whose firewall flip is deferred, DNS.md), the machine
  # keeps the fleet default: on: sshd, Tailscale and node-exporter are all
  # that listen, and tailscale0 is trusted (networking.nix).
}
