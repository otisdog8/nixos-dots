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

{
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
      mount -t btrfs /dev/mapper/luks /btrfs_tmp
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
      cp /btrfs_tmp/persist/secret.jwe /btrfs_tmp/root/etc/clevis/dev/disk/by-id/ata-HUH721212ALE601_2AG2SR1Y.jwe || echo
      umount /btrfs_tmp
    '';
  };

  environment.persistence."/persist" = {
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
        {
          directory = ".ssh";
          mode = "0700";
        }
      ];
      files = [
        ".bash_history"
        ".zsh_history"
      ];
    };
  };
  environment.persistence."/large" = {
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
  environment.persistence."/cache" = {
    enable = true;
    hideMounts = true;
    directories = [ ];
    users.jrt = {
      directories = [ ];
    };
  };

  # Baked - immutable setup-time data (read-only mount)
  # Used for: encryption keys, certificates, machine secrets
  environment.persistence."/baked" = {
    enable = true;
    hideMounts = true;
    directories = [ ];
    users.jrt = {
      directories = [
        # Rarely used by user apps - mostly system-level secrets
      ];
    };
  };
}
