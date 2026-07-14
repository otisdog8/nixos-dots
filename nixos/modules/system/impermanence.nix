# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).
{
  config,
  hostname,
  inputs,
  lib,
  modulesPath,
  outputs,
  pkgs,
  platform,
  stateVersion,
  username,
  ...
}:
let
  cfg = config.modules.system.impermanence;
in
{
  options.modules.system.impermanence.rollbackDevice = lib.mkOption {
    type = lib.types.str;
    default = "/dev/mapper/luks";
    description = ''
      Block device of the btrfs pool whose `root` subvolume the initrd rollback
      service wipes on every boot. Override on hosts whose LUKS mapper is not
      named "luks" (e.g. the roaming liveusb, which uses cryptliveusb to avoid
      colliding with the minting host's own /dev/mapper/luks).
    '';
  };

  config = {
  boot.initrd.systemd.services.rollback = {
    description = "Rollback BTRFS root subvolume to a pristine state";
    wantedBy = [
      "initrd.target"
    ];

    after = [
      # LUKS/TPM process
      "initrd-root-device.target"
    ];
    before = [
      "sysroot.mount"
    ];
    unitConfig.DefaultDependencies = "no";
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir /btrfs_tmp
      mount -t btrfs ${cfg.rollbackDevice} /btrfs_tmp
      if [[ -e /btrfs_tmp/root ]]; then
          mkdir -p /btrfs_tmp/old_roots
          timestamp=$(date --date="@$(stat -c %Y /btrfs_tmp/root)" "+%Y-%m-%-d_%H:%M:%S")
          mv /btrfs_tmp/root "/btrfs_tmp/old_roots/$timestamp"
      fi

      delete_subvolume_recursively() {
          IFS=$'\n'
          for i in $(btrfs subvolume list -o "$1" | cut -f 9- -d ' '); do
              delete_subvolume_recursively "/btrfs_tmp/$i"
          done
          btrfs subvolume delete "$1"
      }

      for i in $(find /btrfs_tmp/old_roots/ -maxdepth 1 -mtime +30); do
          delete_subvolume_recursively "$i"
      done

      btrfs subvolume create /btrfs_tmp/root
      mkdir -p /btrfs_tmp/root/etc/clevis/dev
      cp /btrfs_tmp/persist/secret.jwe /btrfs_tmp/root/etc/clevis/dev/nvme1n1.jwe || echo
      mkdir -p /btrfs_tmp/root/etc/clevis/dev/disk/by-uuid
      cp /btrfs_tmp/persist/secret.jwe /btrfs_tmp/root/etc/clevis/dev/disk/by-uuid/bd79c925-1d8b-4e56-b91b-c1c4c5c303fc.jwe || echo
      mkdir -p /btrfs_tmp/root/etc/clevis/dev/disk/by-id
      cp /btrfs_tmp/persist/secret.jwe /btrfs_tmp/root/etc/clevis/dev/disk/by-id/ata-HUH721212ALE601_2AG2SR1Y.jwe || echo
      umount /btrfs_tmp
    '';
  };

  # impermanence creates the ~/.ssh parent for the persisted key files (below)
  # with default 0755 perms. Force it to 0700 from early boot — before the
  # home-manager fixSshConfigPermissions hook also fixes it — so the private
  # key never sits in a group/world-listable directory.
  systemd.tmpfiles.rules = [ "d /home/jrt/.ssh 0700 jrt users - -" ];

  environment.persistence = {
    "/persist" = {
      enable = true; # NB: Defaults to true, not needed
      hideMounts = true;
      directories = [
        "/root/.ssh/"
        "/var/lib/nixos"
        "/var/lib/systemd"
        "/var/lib/acme"
        "/etc/nixos"
        "/etc/clevis"
      ];
      files = [
        "/etc/machine-id"
        "/root/.bash_history"
      ];
      users.jrt = {
        directories = [
          "Music"
          "Pictures"
          "Documents"
          "Videos"
          ".minecraft"
          ".config/minecraft"
          ".config/op"
        ];
        # NB: ~/.ssh is deliberately NOT persisted as a directory. Persisting
        # the whole dir let an attacker with home-folder write drop a malicious
        # ~/.ssh/config (ProxyCommand / Match exec runs on every ssh + git push)
        # or an authorized_keys entry that survived reboot. Instead we persist
        # only the private key material; ~/.ssh/config is regenerated read-only
        # each boot by home-manager (mixins/cli), and authorized_keys is ignored
        # by sshd (authorizedKeysInHomedir=false in remote-access.nix). The .ssh
        # dir itself is recreated 0700 by the HM fixSshConfigPermissions hook.
        files = [
          ".bash_history"
          ".zsh_history"
          ".ssh/id_ed25519"
          ".ssh/id_ed25519.pub"
          ".ssh/known_hosts"
        ];
      };
    };
    
    "/large" = {
      enable = true;
      hideMounts = true;
      directories = [
        "/var/log"
      ];
      users.jrt = {
        directories = [
          "Downloads"
        ];
      };
    };
    
    "/cache" = {
      enable = true;
      hideMounts = true;
      directories = [ ];
      users.jrt = {
        directories = [ ];
      };
    };

    # Baked - immutable setup-time data (read-only mount)
    # Used for: encryption keys, certificates, machine secrets
    "/baked" = {
      enable = true;
      hideMounts = true;
      directories = [ ];
      users.jrt = {
        directories = [
          # Rarely used by user apps - mostly system-level secrets
        ];
      };
    };
  };
  };
}
