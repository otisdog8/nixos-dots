# Building blocks shared by every crosvm VM on the host: the app sandbox VMs
# (lib/vm/instance.nix) and the agent VM (nixos/modules/system/agent-vm.nix).
#
# Only the pieces whose security properties must not drift apart live here: the
# guest's network path (passt + its unit), the VMM's own sandbox, the jailed
# device processes' syscall filter, the shared-directory flags, and vsock CID
# allocation. Everything app-specific (display, audio, D-Bus, capture, camera,
# launchers) stays in instance.nix; everything agent-specific in agent-vm.nix.
{ lib, pkgs }:
rec {
  passt = import ./passt.nix pkgs;
  cid = import ./cid.nix { inherit lib pkgs; };
  hardening = import ./hardening.nix;
  net = import ./net.nix { inherit lib pkgs passt; };

  # virtio-fs flags common to every share. POSIX ACLs and security contexts
  # stay host-side.
  fsCommon = "type=fs:posix_acl=false:security_ctx=false";
  # The host's store, read-only by the guest's own mount (tag "nixstore").
  storeShare = "/nix/store:nixstore:${fsCommon}:cache=always:timeout=3600";
}
