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
      mkdir -p /btrfs_tmp/root/etc/clevis/dev/disk/by-id
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
      "/root/.config/borg"
      "/var/lib/tailscale"
      "/var/lib/bluetooth"
      "/var/lib/nixos"
      "/var/lib/systemd"
      "/var/lib/tlp"
      "/var/lib/upower"
      "/var/lib/acme"
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
        # ".steam" # Now managed by modules/apps/steam.nix
        ".cargo"
        # ".lunarclient" # Now managed by modules/apps/lunar-client.nix
        ".minecraft"
        # ".config/lunarclient" # Now managed by modules/apps/lunar-client.nix
        ".config/minecraft"
        ".config/op"
        ".config/github-copilot"
        # ".config/Proton" # Now managed by modules/apps/protonvpn-gui.nix
        # ".config/Marvin" # Now managed by modules/apps/amazing-marvin.nix
        ".config/nvim"
        # ".config/obs-studio" # Now managed by modules/apps/obs-studio.nix
        # ".config/tetrio-desktop" # Now managed by modules/apps/tetrio-desktop.nix
        # ".config/obsidian" # Now managed by modules/apps/obsidian.nix
        # ".config/vesktop" # Now managed by modules/apps/vesktop.nix
        # ".config/BraveSoftware" # Now managed by modules/apps/brave.nix
        # ".config/chromium" # Now managed by modules/apps/chromium.nix
        ".cache/cliphist"
        ".claude"
        ".local/share/direnv"
        ".local/state/nvim/"
        ".local/share/nvim/"
        ".local/share/FasterThanLight"
        ".local/share/Paradox Interactive/Stellaris/"
        {
          directory = ".config/1Password";
          mode = "0700";
        }
        {
          directory = ".local/share/kwalletd/";
          mode = "0700";
        }
        { directory = ".local/share/zoxide/"; }
        {
          directory = ".ssh";
          mode = "0700";
        }
        {
          directory = ".1password";
          mode = "0700";
        }
      ];
      files = [
        # ".config/zoom.conf" # Now managed by modules/apps/zoom.nix
        # ".config/zoomus.conf" # Now managed by modules/apps/zoom.nix
        ".bash_history"
        ".zsh_history"
        ".face.icon"
        ".face"
        ".kwalletrc"
        ".claude.json"
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
        # ".local/share/PrismLauncher" # Now managed by modules/apps/prismlauncher.nix
        # ".local/share/Steam" # Now managed by modules/apps/steam.nix
        # ".local/share/slipstream" # Now managed by modules/apps/slipstream.nix
      ];
    };
  };
  environment.persistence."/cache" = {
    enable = true;
    hideMounts = true;
    directories = [
      "/var/cache/jellyfin"
    ];
    users.jrt = {
      directories = [
        ".cache/uv"
      ];
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
