# Persistent, shared on-disk Nix store for sandboxed apps.
#
# Inside a nixpak/bubblewrap sandbox there is no /nix/var/nix (no daemon socket,
# no SQLite db) and the host /nix/store is bind-mounted read-only. As a non-root
# user Nix therefore can't use the local store directly and falls back to a
# private "chroot store" at ~/.local/share/nix/root (made to appear at /nix/store
# via a user namespace).
#
# The bwrap root is a tmpfs, so by default that chroot store is RAM-backed: any
# `nix build`/`develop`/`shell`/`flake` realises closures into RAM and quickly
# exhausts tmpfs.
#
# This feature fixes that without exposing the host nix-daemon:
#   - Backs the chroot store on the compressed /cache btrfs subvolume (on disk)
#     by persisting ~/.local/share/nix/root. apps.nix then also bind-mounts that
#     path rw into the sandbox automatically.
#   - The backing path (/cache/home/<user>/.local/share/nix/root) is a single
#     per-user location, so every sandboxed app that imports this feature shares
#     one store instead of each rebuilding its own.
#   - Mounts host /etc/nix read-only so client-side experimental-features
#     (nix-command, flakes) and substituters are honoured inside the sandbox.
#
# Note: because the daemon/db are not exposed, the store still can't see the
# host's existing /nix/store paths, so closures are fetched from substituters on
# first use. They then persist on /cache and are reused across runs and apps.
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app = {
    # Relocate the chroot store off tmpfs onto on-disk /cache. apps.nix binds
    # every persistence.user.cache path rw into the sandbox for us.
    persistence.user.cache = [
      ".local/share/nix/root"
    ];

    nixpakModules = [
      (_: {
        bubblewrap.bind.ro = [
          # Enables experimental-features / substituters config inside the sandbox.
          "/etc/nix"
        ];
      })
    ];
  };
}
