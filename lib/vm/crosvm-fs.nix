# crosvm for the folder-grants share (`crosvm device fs --allowlist-socket-path`,
# lib/vm/instance.nix). The allowlist listener checks the socket it inherits with
# getsockopt(SOL_SOCKET, SO_ACCEPTCONN), which the fs device's seccomp policy
# doesn't allow, so the jailed device dies with SIGSYS as it starts. Allow exactly
# that call (SOL_SOCKET = 1, SO_ACCEPTCONN = 30 on x86_64 and aarch64).
pkgs:
pkgs.crosvm.overrideAttrs (old: {
  pname = "crosvm-grantsfs";
  postPatch = (old.postPatch or "") + ''
    for a in x86_64 aarch64; do
      printf '\ngetsockopt: arg1 == 1 && arg2 == 30\n' >> jail/seccomp/$a/fs_device.policy
    done
  '';
})
