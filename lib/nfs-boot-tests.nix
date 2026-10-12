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
  evaluated = import (nixpkgs + "/nixos/lib/eval-config.nix") {
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
    ];
  };
  cfg = evaluated.config;
  mountd = cfg.systemd.services.nfs-mountd;
  server = cfg.systemd.services.nfs-server;
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
    persistsNfsState = lib.any (
      entry: entry.directory == "/var/lib/nfs"
    ) cfg.environment.persistence."/persist".directories;
    preservesExportScope =
      cfg.services.nfs.server.exports == ''
        /export/k8s  100.64.0.0/10(rw,nohide,insecure,no_subtree_check,all_squash)
      '';
    noReverseOrdering = !(builtins.elem "nfs-server.service" mountd.after);
    moduleAssertions = lib.all (a: a.assertion) cfg.assertions;
  };
in
if lib.all (x: x) (lib.attrValues results) then
  "ALL NFS BOOT TESTS PASS"
else
  throw "NFS boot tests FAILED: ${builtins.toJSON results}"
