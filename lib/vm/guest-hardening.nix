# The hosts' runtime hardening (nixos/modules/system/hardening.nix), in the app
# VMs' guest (guest.nix) and the agent VM's (agent-guest.nix). The kernel is
# lib/vm/guest-kernel.nix by default (modules.sandbox.vm.guestKernel =
# "minimal"): most of what the blocklists name isn't built there, and its
# module adds the command-line switches for that kernel's hardening options
# (page_table_check=on) and skips the sysctls it lacks (skipSysctls). The
# vm-guest profile keeps what a guest needs: no IP forwarding, no /tmp tmpfs
# (/ already is one), no SysRq, no init_on_free or forced PTI on the command
# line (CPU cost; init_on_alloc stays at the kernel's default, on in both the
# minimal and the host kernel), 32-bit kept (the game VMs), V4L2 and sound
# kept (cameras attach as USB devices). What boot.kernelModules and the
# initrd's lists name is never blocked (overlay, btrfs, the nvgpu kmod; and
# virtio, vsock and virtiofs, which the minimal kernel builds in); what the
# setup units modprobe later (dm_crypt, xts and AES for the swap, uhid,
# hid_generic, ntsync, virtio_gpu_nv) is on no list, which is checked, not
# guaranteed.
#
# TODO: kernel.modules_disabled=1 once boot is done. Not yet: modules load
# for the whole life of an app VM, not just at boot. sbx-setup's
# virtio_gpu_nv, sbx-swap's dm_crypt/xts (the disk can appear late),
# sbx-fido's uhid (started on demand), uvcvideo/videodev/snd_usb_audio when
# a camera is attached later (`sandbox-vm camera`), hid_generic for the FIDO
# device, nested bwrap's lazily loaded netfilter (the minimal kernel has
# only the firewall's, and no tun). It would
# need a preload list from each VM's spec (one guest system serves them all)
# and a oneshot ordered after all of those, or the census
# (modprobe-census.nix) to show the set is closed.
{ lib, pkgs, ... }:
{
  imports = [ ../../nixos/modules/system/hardening.nix ];

  modules.system.hardening = {
    enable = true;
    profile = "vm-guest";
    # No Bluetooth in a VM (the hosts block it too); cryptsetup's plainOpen
    # (sbx-swap) doesn't need AF_ALG, as the hosts' randomEncryption swap shows.
    blacklistAfAlg = true;
  };

  # NixOS loads atkbd everywhere, but crosvm runs these VMs without an i8042
  # (--no-i8042: instance.nix, agent-vm.nix). The minimal kernel has no atkbd
  # at all; with the host kernel, dropping it here keeps systemd-modules-load
  # from tripping over the install rule below.
  boot.kernelModules.atkbd = lib.mkForce false;
  boot.blacklistedKernelModules = [ "atkbd" ];
  boot.extraModprobeConfig = ''
    install atkbd ${pkgs.coreutils}/bin/false
  '';
}
