# munificent, the machine, as a hypervisor (modules/system/node-vm.nix): it
# runs the k3s node "munificent" as a VM (hosts/munificent-node) and nothing
# else. The node took this machine's identity with it — its ssh host keys,
# Tailscale state (100.65.16.13), machine-id, hostd pairing and the LAN NIC's
# MAC, so its DHCP lease — and this machine starts over as munificent-hv.
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
  networking.hostName = "munificent-hv";

  # Device interrupts on the host's own CPUs, off the node VM's pinned ones
  # (modules.system.nodeVms.node.pinCpus).
  boot.kernelParams = [ "irqaffinity=0-5" ];
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
    # VM's, which unlocks it (hosts/munificent-node).
    system.cephOsdDisk.enable = true;

    system.zswap.enable = true;

    system.hardening = {
      enable = true;
      profile = "server";
      blacklistAfAlg = true;
      # Scheduler tuning and inspection for the node VM (/sys/kernel/debug/sched).
      debugfs = true;
    };

    # The same root LUKS as the bare-metal node, so the same PCR 15.
    system.pcr-verification = {
      enable = true;
      deviceName = "cryptmunificent";
      expectedPcr15 = "96b5ee925510b8893c50581cfbd34a7ccf341981a3b576a577b1ea5076a85af4";
    };

    # To the default collector, arquitens's node: another machine's VM
    # (this one can't reach its own over the LAN, node-vm.nix).
    system.netconsole.enable = true;

    # The node VMs' unit, proven on a throwaway guest (node-vm.nix).
    system.nodeVmSmoke = {
      enable = true;
      parentInterface = "enp4s0f4u1";
    };

    system.nodeVms.node = {
      guest = outputs.nixosConfigurations.munificent-node;
      # 64 GB machine: ~4 GiB for itself, room for the sensitive cluster's VM
      # later (docs/node-vms.md).
      memoryMiB = 46 * 1024;
      # 12 of the machine's 16 threads: the rest is for the host and
      # crosvm's device processes (the VM's disk and network). At 14, a
      # restart storm (all three nodes at once, Ceph recovering, ~400 pods
      # starting) soft-locked every vCPU of arquitens for 20-30 s (2026-10-21
      # 22:42 PDT). Pods request ~29 CPUs across the cluster, so 10 (room for
      # the sensitive cluster's VM) needs those requests trimmed first.
      vcpus = 10;
      # Pilot of pinning + isolation (node-vm.nix pinCpus): vCPU i on host
      # CPU 6+i, the last five cores (siblings are 2k/2k+1); the host keeps
      # CPUs 0-5 (IRQs below). CPU steal was 25-48% of what the VM wanted
      # (2026-10-25), ~200 us per vCPU wake-up queueing with host CPUs idle.
      pinCpus = [ 6 7 8 9 10 11 12 13 14 15 ];
      # The USB dongle's own MAC: the node keeps 10.0.0.12 and netconsole's
      # "munificent" entry (whose device is the MAC's enx altname).
      mac = "00:24:27:88:a9:cd";
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
          device = "/dev/disk/by-id/ata-MTFDDAK1T9TDS_221436ADE602";
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
    matchConfig.PermanentMACAddress = "00:24:27:88:a9:cd";
    linkConfig = {
      MACAddress = "02:24:27:88:a9:cd";
      NamePolicy = "keep kernel database onboard slot path";
      AlternativeNamesPolicy = "database onboard slot path mac";
    };
  };

  # First Tailscale login as munificent-hv: a one-off auth key, put there by
  # hand at the conversion and deleted after (docs/node-vms.md).
  services.tailscale.authKeyFile = "/persist/tailscale-hv.authkey";

  services.agent-auth-hostd.enable = lib.mkForce false;

  # Unlike the nodes (whose firewall flip is deferred, DNS.md), the machine
  # keeps the fleet default: on: sshd, Tailscale and node-exporter are all
  # that listen, and tailscale0 is trusted (networking.nix).
}
