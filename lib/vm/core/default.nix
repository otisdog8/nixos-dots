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

  # The host filesystems a VM's host unit never sees: every one mounted outside
  # the system's own trees (a btrfs top level holds every subvolume, the
  # user's home included), and the data tiers. `fileSystems`: the host's
  # config.fileSystems.
  hiddenMounts =
    fileSystems:
    let
      keep =
        p:
        p == "/"
        || lib.any (k: p == k || lib.hasPrefix "${k}/" p) [
          "/nix"
          "/etc"
          "/var"
          "/run"
          "/tmp"
          "/usr"
          "/proc"
          "/sys"
          "/dev"
          "/home"
          "/root"
        ];
    in
    lib.unique (
      [
        "/persist"
        "/large"
        "/cache"
      ]
      ++ lib.filter (p: !keep p) (lib.attrNames fileSystems)
    );

  # World-connectable sockets under /run that resolve names for whoever asks
  # (resolved's varlink API, nscd's hosts cache, avahi's mDNS): through them a
  # unit with no network of its own, or passt under an allowNames policy,
  # could make the host send DNS queries of its choosing. Only the sockets:
  # passt reads /etc/resolv.conf, resolved's stub file in the same folder.
  hostResolvers = [
    "/run/systemd/resolve/io.systemd.Resolve"
    "/run/systemd/resolve/io.systemd.Resolve.Monitor"
    "/run/nscd"
    "/run/avahi-daemon"
  ];

  # InaccessiblePaths for a VM's host unit: `hiddenMounts`, the system bus
  # (where polkit lets users start and stop units), `hostResolvers`, the root
  # attach helper's socket, and `hide` (more paths, "-" prefixed as needed).
  # ProtectHome= (the unit's) hides /home and /run/user. (lib/vm/instance.nix
  # `view` builds the app VMs' from the same parts.)
  hostView =
    {
      fileSystems,
      hide ? [ ],
    }:
    {
      InaccessiblePaths =
        map (p: "-${p}") (hiddenMounts fileSystems ++ [ "/run/dbus" ] ++ hostResolvers ++ [ "/run/sbx-attach.sock" ])
        ++ hide;
    };

  # An app VM's own host uid (and group), which its VMM and guest-facing host
  # services run as instead of the desktop user (lib/vm/instance.nix
  # `vmUser`); others (op-broker) name it to let that VM's relay in.
  vmUserName =
    name:
    let
      n = "sbx-vm-${name}";
    in
    # 31: the longest group name NixOS accepts.
    if lib.stringLength n <= 31 then
      n
    else
      "sbx-vm-${builtins.substring 0 16 (builtins.hashString "sha256" name)}";
}
