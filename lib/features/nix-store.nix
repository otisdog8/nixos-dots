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
#   - Bind-mounts ~/.local/share/nix/root rw into the sandbox so the chroot store
#     lands on the host's real (on-disk) home rather than the tmpfs bwrap root.
#   - The backing path is a single per-user location, so every sandboxed app that
#     imports this feature shares one store instead of each rebuilding its own.
#   - Mounts host /etc/nix read-only so client-side experimental-features
#     (nix-command, flakes) and substituters are honoured inside the sandbox.
#
# The on-disk backing of ~/.local/share/nix/root (on the compressed /cache
# subvolume) is declared ONCE in modules/system/developer-tools.nix. It must not
# be added per-app via persistence.user.cache: multiple apps importing this
# feature would then register the same user directory twice and impermanence
# asserts on duplicate persistence entries.
#
# Note: because the daemon/db are not exposed, the store still can't see the
# host's existing /nix/store paths, so closures are fetched from substituters on
# first use. They then persist on /cache and are reused across runs and apps.
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    (
      { sloth, ... }:
      {
        bubblewrap.bind.rw = [
          # Chroot store, backed on-disk + persisted via developer-tools.nix.
          (sloth.concat' sloth.homeDir "/.local/share/nix/root")
        ];
        bubblewrap.bind.ro = [
          # Enables experimental-features / substituters config inside the sandbox.
          "/etc/nix"
        ];
      }
    )
  ];
}
