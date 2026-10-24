# The k3s cluster token, from sops-nix instead of git-crypt.
#
# With `services.k3s.token` (set from the git-crypted secrets.nix) the token ends up in the k3s
# unit as `--token <value>`: world-readable in /nix/store on the node and its hypervisor, and in
# k3s's command line for any local user to read with `ps`. sops-nix decrypts it at activation
# into /run/secrets/k3s-token (root, 0400) and k3s reads it via --token-file, so it is in neither.
#
# The node's age identity is its SSH host key, read from /persist (neededForBoot) so it is there
# when activation runs. Unlike the Ceph disk key (ceph-osd-disk.nix) nothing needs the token
# before activation: k3s starts long after.
#
# k3s-token.yaml holds the cluster's current token (the full K10... form from
# /var/lib/rancher/k3s/server/token), encrypted on a node without leaving it. Rotating: see
# the comment at the end.
{ config, inputs, lib, ... }:
{
  imports = [ inputs.sops-nix.nixosModules.sops ];

  sops.age.sshKeyPaths = [ "/persist/etc/ssh/ssh_host_ed25519_key" ];
  sops.gnupg.sshKeyPaths = [ ];
  sops.secrets.k3s-token = {
    sopsFile = ./k3s-token.yaml;
    # No restartUnits: a changed token must not restart k3s by itself (see rotation below).
  };

  # Whatever secrets.nix still sets, the token now comes only from the file.
  services.k3s.token = lib.mkForce "";
  services.k3s.tokenFile = config.sops.secrets.k3s-token.path;

  # Rotation (k3s >= 1.28), because the old token has been readable on these hosts:
  #  1. etcd snapshot; LivePods held still (lcm's agent and wake tokens derive from this token).
  #  2. On one server: k3s token rotate --token "$(cat /var/lib/rancher/k3s/server/token)" \
  #       --new-token "$NEW"
  #  3. Re-encrypt k3s-token.yaml with $NEW (sops k3s-token.yaml from an admin host) and deploy;
  #     restart the servers one at a time with the new file. Never start a server on the old
  #     token after step 2.
  #  4. Copy the new /run/lcm/wake-token into the VPS gateways' credstore
  #     (live-container-migration deploy/standalone/README.md).
}
