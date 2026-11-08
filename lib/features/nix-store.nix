# Nix inside the sandbox, through sbx-nix (modules/system/sandbox-nix.nix).
#
# Inside a nixpak/bubblewrap sandbox there is no /nix/var/nix, and the host's
# nix-daemon is never exposed: it runs as root, and any client reaches its
# whole protocol. Where the host runs sbx-nix (/etc/sbx-nix/enabled), the
# sandbox talks to that instead: an unprivileged daemon serving a local-overlay
# store, the host's /nix/store as the read-only lower layer (so the host's
# paths are there already, not fetched again), its own upper layer for what
# sandboxes build or substitute. Only the daemon writes that layer; a sandbox
# can't change what another one later runs.
#
#   - /run/sbx-nix/nix is bound read-only at /nix: the merged store at
#     /nix/store (the host's paths plus the upper layer's, so outputs that exist
#     only in the upper layer run), and the daemon's socket at
#     /nix/var/nix/daemon-socket/socket. It is the PARENT of the store's mount
#     point that is bound, so a remount (sbx-nix-refresh) reaches running
#     sandboxes too. bubblewrap.bind.afterStore (our nixpak patch,
#     backends/nixpak-pkg.nix) puts it after nixpak's own --ro-bind of the
#     host /nix/store, which it covers.
#   - A sandbox started inside one (nested bwrap) binds the outer one's /nix
#     the same way: the view carries a marker (/nix/var/nix/sbx-nix-view).
#   - Only when sbx-nix is up: the wrapper checks for the socket and that the
#     view's store holds a path of this sandbox's own closure (the base layer
#     is mounted). Otherwise the sandbox keeps nixpak's plain read-only host
#     store and `nix` fails to connect, loudly (NIX_REMOTE=daemon), instead of
#     falling back to a store every sandbox can write.
#   - The sandboxes run as the user (no write access to /nix/var/nix, which
#     `auto` would also find), and allowed-users admits them
#     (modules.sandbox.nixDaemon.allowedUsers).
#
# Hosts without sbx-nix (servers, k3s nodes) keep what was there before: each
# sandbox runs nix against the per-user chroot store ~/.local/share/nix/root,
# bound read-write (its on-disk backing: modules/system/developer-tools.nix,
# declared once there, never per app). Every sandbox can write it.
#
# Either way host /etc/nix is mounted read-only so client-side
# experimental-features (nix-command, flakes) are honoured inside the sandbox.
# On NixOS /etc/nix/{nix.conf,registry.json} are symlinks into /etc/static, so
# /etc/static/nix is bound too — otherwise they dangle and nix runs with
# built-in defaults ("experimental Nix feature 'nix-command' is disabled").
{ pkgs, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app.usesSandboxNix = true;

  config.app.nixpakModules = [
    (
      { sloth, ... }:
      {
        bubblewrap.preLaunch = ''
          unset SBX_NIX_VIEW SBX_NIX_CHROOT
          if [ -e /nix/var/nix/sbx-nix-view ]; then
            # Started inside a sandbox that has sbx-nix's view at /nix (only
            # that view has the marker; the host's /nix/var/nix never does):
            # the same view, the same daemon, never the chroot store.
            export SBX_NIX_REMOTE=daemon
            if [ -S /nix/var/nix/daemon-socket/socket ]; then
              export SBX_NIX_VIEW=/nix
            fi
          elif [ -e /etc/sbx-nix/enabled ] || [ -e /run/sbx-nix/nix/var/nix/sbx-nix-view ]; then
            export SBX_NIX_REMOTE=daemon
            if [ -S /run/sbx-nix/nix/var/nix/daemon-socket/socket ] \
              && [ -e /run/sbx-nix${pkgs.coreutils} ]; then
              export SBX_NIX_VIEW=/run/sbx-nix/nix
            fi
          else
            export SBX_NIX_REMOTE=auto SBX_NIX_CHROOT="$HOME/.local/share/nix/root"
          fi
        '';
        bubblewrap.bind.afterStore = [
          [
            (sloth.envOr "SBX_NIX_VIEW" "/var/empty/.sbx-no-nix")
            "/nix"
          ]
        ];
        bubblewrap.env.NIX_REMOTE = sloth.envOr "SBX_NIX_REMOTE" "daemon";
        bubblewrap.bind.rw = [
          # Hosts without sbx-nix: the chroot store.
          [
            (sloth.envOr "SBX_NIX_CHROOT" "/var/empty/.sbx-no-nix")
            (sloth.concat' sloth.homeDir "/.local/share/nix/root")
          ]
        ];
        bubblewrap.bind.ro = [
          # Enables experimental-features config inside the sandbox.
          "/etc/nix"
          # Targets of the /etc/nix symlinks (nix.conf, registry.json, …).
          "/etc/static/nix"
        ];
      }
    )
  ];
}
