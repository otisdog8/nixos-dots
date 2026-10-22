# NFS for the k3s cluster: /export/k8s (the bcachefs pool's k8s tree: media,
# Immich, Paperless), NFSv4.2 only, to the three k3s nodes, on the tailnet.
#
# Design
#   - NFSv4.2 only. v2/v3/4.0/4.1 are off in nfs.conf, so nothing but TCP 2049
#     is served: no rpcbind (111), no MOUNT listener from rpc.mountd, no
#     lockd/NLM, no rpc.statd. rpc.mountd still runs, with no sockets: the
#     kernel asks it which client gets which export.
#   - No rpc.idmapd. Every request is squashed to nobody (all_squash, anon
#     65534), and with AUTH_SYS the kernel sends and takes owners as numbers
#     (nfsd's nfs4_disable_idmapping, pinned below), so there is nothing to map.
#   - nfsdcld keeps the NFSv4 client records (who may reclaim locks in the
#     grace period after a restart) in /persist directly, through nfs.conf.
#     Nothing is bind-mounted over /var/lib/nfs: it lives on the wiped root,
#     and rpc_pipefs (which nfsdcld talks to the kernel through) is mounted
#     at /var/lib/nfs/rpc_pipefs. A bind mount of /var/lib/nfs started after
#     that hides it (2026-10-21: idmapd failed after a nixpkgs update); the
#     assertion below keeps one from coming back.
#   - Exported to the nodes' tailnet addresses only, from reserved ports
#     (secure, the default: `insecure` is gone). nfsd listens on recusant's
#     tailnet address only, and the firewall leaves 2049 to tailscale0 (a
#     trusted interface fleet-wide), so it is not opened anywhere else.
#     Pods' traffic reaches here masqueraded as their node's address, so
#     these can't tell a pod from the node's kubelet; homelab's
#     apps/infra/nfs/deny-pod-nfs.yaml keeps pods off 2049.
#   - Clients pin vers=4.2,hard (modules/system/k3s/nfs.nix: nfsmount.conf
#     on the nodes, which kubelet's mounts of pods' nfs volumes read too).
#
# Verify (on recusant)
#   rpcinfo -p                  fails: rpcbind isn't running (nothing on 111)
#   ss -ltn                     2049 on 100.110.239.45 only; no 111, no mountd
#   cat /proc/fs/nfsd/versions  -3 +4 -4.0 -4.1 +4.2
#   exportfs -v                 /export/k8s to the three node IPs, with
#                               rw,secure,root_squash,all_squash, no insecure
#   nfsstat -s                  only the "Server nfs v4" tables have counts
#   systemctl status nfs-server nfs-mountd nfsdcld var-lib-nfs-rpc_pipefs.mount
#   ls /proc/fs/nfsd/clients/*/info   one per node, `minor version: 2`
#   findmnt /var/lib/nfs        nothing: no bind mount over the state dir
#   findmnt /var/lib/nfs/rpc_pipefs   rpc_pipefs, visible
# and from a node:
#   ls /mnt/net-k8s             automounts the export (vers=4.2 from
#                               /etc/nfsmount.conf)
#   mount -t nfs -o vers=3 100.110.239.45:/export/k8s /mnt/t   must fail
#   findmnt -t nfs4 -o TARGET,SOURCE,OPTIONS   vers=4.2,hard on every mount
# and from a pod: `nc -zw3 100.110.239.45 2049` times out (deny-pod-nfs).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  tailscaleIp = "100.110.239.45";

  # The k3s nodes' tailnet addresses (hosts/*-node). Pods mount through their
  # node's kubelet, from these addresses.
  nodes = {
    arquitens = "100.126.30.73";
    carrack = "100.103.225.29";
    munificent = "100.65.16.13";
  };

  exportOptions = [
    "rw"
    "sync"
    "secure"
    "no_subtree_check"
    "nohide"
    "root_squash"
    "all_squash"
  ];

  # nfsdcld's database (main.sqlite). The same directory the old bind mount
  # of /persist/var/lib/nfs showed it at, so the records carry over.
  cldDir = "/persist/var/lib/nfs/nfsdcld";

  persistedDirs = lib.concatMap (p: map (d: d.directory) p.directories) (
    lib.filter (p: p.enable) (lib.attrValues config.environment.persistence)
  );
in
{
  assertions = [
    {
      assertion =
        !lib.any (d: lib.hasPrefix "${lib.removeSuffix "/" d}/" "/var/lib/nfs/rpc_pipefs") persistedDirs;
      message = ''
        recusant/nfs.nix: environment.persistence covers /var/lib/nfs. Its bind
        mount can land on top of /var/lib/nfs/rpc_pipefs and hide it from
        nfsdcld. Persist what must survive in place instead, as nfsdcld's
        storagedir is.
      '';
    }
  ];

  services.nfs.server = {
    enable = true;
    hostName = tailscaleIp;
    exports = {
      "/export/k8s" = lib.mapAttrs' (_: ip: lib.nameValuePair ip exportOptions) nodes;
    };
  };

  services.nfs.settings = {
    nfsd = {
      # The module's own threads= is lost once hostName is set (it merges
      # the two with a shallow //), so say it here.
      threads = config.services.nfs.server.nproc;
      vers2 = false;
      vers3 = false;
      "vers4.0" = false;
      "vers4.1" = false;
      "vers4.2" = true;
      udp = false;
      tcp = true;
    };
    nfsdcld.storagedir = cldDir;
  };

  # Binding the tailnet address works before tailscale0 has it at boot (also
  # set for nginx, hermes-homelab-recusant.nix). Without it nfsdctl's listener
  # would fail, and nfsdctl then starts zero threads and can still exit 0; the
  # check below turns that into a failed unit.
  boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = lib.mkDefault 1;

  # Numeric owners for AUTH_SYS (the kernel's default, pinned): what lets
  # rpc.idmapd go.
  boot.extraModprobeConfig = ''
    options nfsd nfs4_disable_idmapping=Y
  '';

  # v4 needs none of these. nfs-server.service only Wants= them, so masking
  # is enough; rpc-statd would otherwise fail for want of rpcbind.
  services.rpcbind.enable = lib.mkForce false;
  systemd.services.rpc-statd.enable = false;
  systemd.services.rpc-statd-notify.enable = false;
  systemd.services.nfs-idmapd.enable = false;

  systemd.tmpfiles.rules = [ "d ${cldDir} 0700 root root -" ];
  systemd.services.nfsdcld.unitConfig.RequiresMountsFor = [ cldDir ];

  # These are nofail mounts: local-fs.target does not guarantee they are ready.
  # Require the actual export before preparing its table or starting the server.
  systemd.services.nfs-server = {
    unitConfig.RequiresMountsFor = [ "/export/k8s" ];
    serviceConfig.ExecStartPost = pkgs.writeShellScript "nfsd-check-threads" ''
      read -r threads < /proc/fs/nfsd/threads
      if [ "''${threads:-0}" -eq 0 ]; then
        echo "nfsd has no threads: a listener failed to start" >&2
        exit 1
      fi
    '';
  };
  systemd.services.nfs-mountd = {
    unitConfig.RequiresMountsFor = [ "/export/k8s" ];
    # Upstream starts mountd before nfs-server's exportfs -r. Netlink cache setup
    # reads etab eagerly and exits if it is missing. Generate it before mountd:
    # /var/lib/nfs is on the wiped root, so every boot starts without one.
    # Let failure abort startup rather than serving without valid exports.
    preStart = ''
      ${pkgs.nfs-utils}/bin/exportfs -r
    '';
  };
}
