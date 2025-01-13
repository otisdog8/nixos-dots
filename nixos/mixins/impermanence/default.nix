
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
    cp /btrfs_tmp/persist/secret.jwe /btrfs_tmp/root/etc/clevis/dev/disk/by-uuid/35e74177-8be0-4de6-90d4-62aa305956db.jwe || echo
    umount /btrfs_tmp
    '';
  };


  environment.persistence."/persist" = {
    enable = true;  # NB: Defaults to true, not needed
    hideMounts = true;
    directories = [
      "/root/.ssh/"
      "/root/.config/borg"
      "/var/lib/tailscale"
      "/var/lib/bluetooth"
      "/var/lib/nixos"
      "/var/lib/systemd"
      "/var/lib/tlp"
      "/var/lib/upower"
      "/var/lib/sabnzbd"
      "/var/lib/jellyfin"
      "/etc/nixos"
      "/etc/secureboot"
      "/var/lib/sbctl"
      "/etc/NetworkManager/system-connections"
      "/etc/clevis"
    ];
    files = [
      "/etc/machine-id"
      "/root/.bash_history"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
    ];
    users.jrt = {
      directories = [
        "Music"
        "Pictures"
        "Documents"
        "Videos"
        ".steam"
        ".zen"
        ".cargo"
        ".emacs.d"
        ".config/op"
        ".config/kdeconnect"
        ".config/vesktop"
        ".config/Proton"
        ".config/BraveSoftware"
        ".config/Marvin"
        ".cache/cliphist"
        { directory = ".config/1Password"; mode = "0700"; }
        { directory = ".local/share/kwalletd/"; mode = "0700"; }
        { directory = ".local/share/zoxide/"; }
        { directory = ".gnupg"; mode = "0700"; }
        { directory = ".ssh"; mode = "0700"; }
        { directory = ".1password"; mode = "0700"; }
      ];
      files = [
         ".bash_history"
         ".zsh_history"
         ".face.icon"
         ".face"
         ".kwalletrc"
      ];
    };
  };
  environment.persistence."/large" = {
    enable = true;
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/libvirt"
      "/var/lib/rancher"
      "/var/lib/rook"
      "/etc/rancher"
    ];
    users.jrt = {
      directories = [
        "Downloads"
        ".local/share/PrismLauncher"
        ".local/share/Steam"
      ];
    };
  };
  environment.persistence."/cache" = {
    enable = true;
    hideMounts = true;
    directories = [
      "/var/cache/jellyfin"
    ];
  };
  environment.persistence."/dots" = {
    enable = true;
    hideMounts = true;
    users.jrt = {
      files = [
        ".spacemacs"
      ];
    };
  };
}
