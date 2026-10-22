# Evaluate the real NixOS NFS units without the host's unrelated secret imports.
# nix-instantiate --eval --strict lib/nfs-boot-tests.nix \
#   --arg nixpkgs /path/to/locked/nixpkgs --arg impermanence /path/to/locked/impermanence
{
  nixpkgs,
  impermanence,
  nfsModule ? ../nixos/hosts/recusant/nfs.nix,
}:
let
  pkgs = import nixpkgs { system = "x86_64-linux"; };
  inherit (pkgs) lib;
  evalWith =
    extra:
    import (nixpkgs + "/nixos/lib/eval-config.nix") {
      system = "x86_64-linux";
      modules = [
        (impermanence + "/nixos.nix")
        nfsModule
        {
          system.stateVersion = "24.05";
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          fileSystems."/persist" = {
            device = "none";
            fsType = "tmpfs";
            neededForBoot = true;
          };
          fileSystems."/mnt/bcachefs" = {
            device = "/dev/test-pool";
            fsType = "ext4";
            options = [ "nofail" ];
          };
          fileSystems."/export/k8s" = {
            device = "/mnt/bcachefs/k8s";
            fsType = "none";
            options = [
              "bind"
              "nofail"
            ];
          };
          environment.persistence."/persist".enable = true;
        }
      ]
      ++ extra;
    };
  evaluated = evalWith [ ];
  cfg = evaluated.config;
  mountd = cfg.systemd.services.nfs-mountd;
  server = cfg.systemd.services.nfs-server;
  nfsConf = builtins.unsafeDiscardStringContext (
    builtins.readFile cfg.environment.etc."nfs.conf".source
  );
  failedAssertions = c: lib.filter (a: !a.assertion) c.assertions;
  results = {
    preparesExportsBeforeMountd = lib.hasInfix (builtins.unsafeDiscardStringContext "${pkgs.nfs-utils}/bin/exportfs -r") (
      builtins.unsafeDiscardStringContext mountd.preStart
    );
    mountdRequiresExportMount = builtins.elem "/export/k8s" (
      mountd.unitConfig.RequiresMountsFor or [ ]
    );
    serverRequiresExportMount = builtins.elem "/export/k8s" (
      server.unitConfig.RequiresMountsFor or [ ]
    );
    noReverseOrdering = !(builtins.elem "nfs-server.service" mountd.after);
    # Nothing bind-mounted over /var/lib/nfs (it would hide rpc_pipefs), and
    # nfsdcld's records kept in /persist directly.
    noNfsStateBindMount =
      !lib.any (
        entry: lib.hasPrefix "/var/lib/nfs" entry.directory
      ) cfg.environment.persistence."/persist".directories;
    cldStorageInPersist = lib.hasInfix "storagedir=/persist/var/lib/nfs/nfsdcld" nfsConf;
    # NFSv4.2 only, on the tailnet address.
    v42Only = lib.all (l: lib.hasInfix l nfsConf) [
      "vers2=false"
      "vers3=false"
      "vers4.0=false"
      "vers4.1=false"
      "vers4.2=true"
      "udp=false"
      "host=100.110.239.45"
      "threads=8"
    ];
    noRpcbind = !cfg.services.rpcbind.enable;
    noStatdOrIdmapd = !cfg.systemd.services.rpc-statd.enable && !cfg.systemd.services.nfs-idmapd.enable;
    notOpenedOutsideTailnet = !builtins.elem 2049 cfg.networking.firewall.allowedTCPPorts;
    exportsToNodesOnly =
      cfg.services.nfs.server.exports
      == "/export/k8s 100.103.225.29(rw,sync,secure,no_subtree_check,nohide,root_squash,all_squash) 100.126.30.73(rw,sync,secure,no_subtree_check,nohide,root_squash,all_squash) 100.65.16.13(rw,sync,secure,no_subtree_check,nohide,root_squash,all_squash)";
    noInsecure = !lib.hasInfix "insecure" cfg.services.nfs.server.exports;
    moduleAssertions = failedAssertions cfg == [ ];
    # The guard: persisting /var/lib/nfs again fails evaluation.
    guardsAgainstStateBindMount = lib.any (a: lib.hasInfix "rpc_pipefs" a.message) (
      failedAssertions
        (evalWith [ { environment.persistence."/persist".directories = [ "/var/lib/nfs" ]; } ]).config
    );
  };
in
if lib.all (x: x) (lib.attrValues results) then
  "ALL NFS BOOT TESTS PASS"
else
  throw "NFS boot tests FAILED: ${builtins.toJSON results}"
