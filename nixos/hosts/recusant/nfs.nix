{ pkgs, ... }:
{
  # Keep NFS state across impermanence's root rollback, including client recovery
  # records. StateDirectory alone only recreates an empty directory each boot.
  environment.persistence."/persist".directories = [ "/var/lib/nfs" ];

  services.nfs.server = {
    enable = true;
    # Scope to the tailnet's CGNAT range, not the public portion of 100.0.0.0/8.
    exports = ''
      /export/k8s  100.64.0.0/10(rw,nohide,insecure,no_subtree_check,all_squash)
    '';
  };
  networking.firewall.allowedTCPPorts = [ 2049 ];

  # These are nofail mounts: local-fs.target does not guarantee they are ready.
  # Require the actual export before preparing its table or starting the server.
  systemd.services.nfs-server.unitConfig.RequiresMountsFor = [ "/export/k8s" ];
  systemd.services.nfs-mountd = {
    unitConfig.RequiresMountsFor = [ "/export/k8s" ];
    # Upstream starts mountd before nfs-server's exportfs -r. Netlink cache setup
    # reads etab eagerly and exits if it is missing. Generate it before mountd,
    # including on first boot when the persisted state directory is still empty.
    # Let failure abort startup rather than serving without valid exports.
    preStart = ''
      ${pkgs.nfs-utils}/bin/exportfs -r
    '';
  };
}
