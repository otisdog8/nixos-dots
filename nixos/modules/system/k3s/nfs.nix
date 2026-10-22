# The NFS client side of recusant's /export/k8s (hosts/recusant/nfs.nix, which
# serves NFSv4.2 only, to these nodes' tailnet addresses).
#
# Pods' nfs volumes (homelab: media, Immich, Paperless) are mounted by kubelet
# through mount.nfs, which reads /etc/nfsmount.conf. An inline nfs volume
# can't carry mountOptions, so they are set here, for every NFS mount the node
# makes: v4.2 or fail (never a silent fall back to v3, which recusant no
# longer serves), hard (a recusant reboot stalls I/O and then resumes, instead
# of handing apps EIO), and the TCP defaults made explicit: retry after 60 s,
# report "server not responding" after 2 retries, keep retrying.
{
  config,
  lib,
  ...
}:
let
  # recusant's tailnet address: no dependence on the short name resolving,
  # which takes resolved, tailscaled's D-Bus handoff and the tailnet search
  # domain all being up (modules/system/dns.nix).
  recusant = "100.110.239.45";
in
{
  config = lib.mkIf config.modules.system.k3s.enable {
    # mount.nfs and the kernel client, for kubelet. Until now these came only
    # by way of the /mnt/net-k8s entry.
    boot.supportedFilesystems = [ "nfs" ];

    environment.etc."nfsmount.conf".text = ''
      [ NFSMount_Global_Options ]
      Nfsvers=4.2
      Proto=tcp
      Hard=True
      Timeo=600
      Retrans=2
    '';

    # NFSv4 needs no portmapper, on either end.
    services.rpcbind.enable = lib.mkForce false;

    # The whole export, for looking at by hand (nothing in the cluster uses
    # it). Mounted on first use, so boot doesn't wait on recusant.
    fileSystems."/mnt/net-k8s" = {
      device = "${recusant}:/export/k8s";
      fsType = "nfs";
      options = [
        "nofail"
        "x-systemd.automount"
        "x-systemd.idle-timeout=10min"
        "x-systemd.mount-timeout=30s"
      ];
    };
  };
}
