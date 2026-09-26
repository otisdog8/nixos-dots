# The generic sandbox-VM guest: ONE NixOS system per host, shared by every app's
# microVM (lib/backends/vm.nix, evaluated in nixos/modules/system/sandbox-vm.nix).
#
# Nothing app-specific is baked in. The guest boots from the host's /nix/store
# (virtio-fs tag "nixstore", read-only), so any store path — the app package, the
# host's system profile — runs unchanged inside it. Per-app wiring arrives at boot:
#   - kernel param sbx.spec=<store path>: the app's JSON spec (storage entries,
#     binds, whether a working directory is attached), built by the vm backend;
#   - virtio-fs tag "sbx-meta" (read-only): per-launch files the host generates —
#     the guest's SSH host key, the host user's authorized key, and the working
#     directory path (for per-project VMs);
#   - virtio-fs tags "sbx-<tier>", "sbx-binds", "sbx-cwd": the data itself.
# sbx-setup.service grafts all of that onto the user's home before the SSH socket
# accepts connections. The host reaches the guest ONLY over vsock SSH (no inbound
# network); outbound networking, when the app has the network capability, is a
# virtio-net NIC backed by a host-side passt (DHCP + DNS from passt).
#
# Guest-side state is disposable: / is a tmpfs, so every boot starts clean apart
# from what the host shares in.
{
  config,
  lib,
  pkgs,
  sbxHost,
  ...
}:
let
  user = sbxHost.user;
  home = "/home/${user}";
  vsockRelay = import ./vsock-relay.nix pkgs;
  grantsPkg = import ./grants.nix pkgs;

  # Mount everything the spec describes. Runs as root before any SSH session.
  setup = pkgs.writeShellScript "sbx-setup" ''
    set -euo pipefail
    user=${user}
    group=${sbxHost.group}
    home=${home}

    arg() {
      local w
      for w in $(cat /proc/cmdline); do
        case "$w" in "$1="*) printf '%s' "''${w#"$1="}"; return 0 ;; esac
      done
    }

    # Create every missing ancestor of $1 (absolute). Under $home they belong to the
    # user (so the app can create siblings); elsewhere to root.
    mkparents() {
      local dir
      dir="$(dirname -- "$1")"
      [ -d "$dir" ] && return 0
      mkparents "$dir"
      case "$dir" in
        "$home"/*) install -d -m 0755 -o "$user" -g "$group" -- "$dir" ;;
        *) install -d -m 0755 -- "$dir" ;;
      esac
    }

    # Bind $1 (a file or directory from a share) onto $2, creating the mount point
    # with the matching type.
    graft() {
      local src="$1" dst="$2" owner=root
      [ -e "$src" ] || { echo "sbx-setup: missing share entry $src, skipped" >&2; return 0; }
      case "$dst" in "$home"/*) owner="$user" ;; esac
      mkparents "$dst"
      if [ -d "$src" ]; then
        [ -d "$dst" ] || install -d -m 0700 -o "$owner" -g "$group" -- "$dst"
      else
        [ -e "$dst" ] || install -m 0600 -o "$owner" -g "$group" /dev/null "$dst"
      fi
      mount --bind -- "$src" "$dst"
    }

    vfs() { install -d -m 0755 "$2"; mount -t virtiofs -o "nosuid,nodev''${3:+,$3}" "$1" "$2"; }

    # Per-launch metadata: SSH keys and (per-project VMs) the working directory.
    vfs sbx-meta /run/sbx/meta ro
    install -d -m 0755 /run/sbx/ssh
    install -m 0600 /run/sbx/meta/ssh_host_ed25519_key /run/sbx/ssh/ssh_host_ed25519_key
    install -m 0644 /run/sbx/meta/authorized_keys /run/sbx/ssh/authorized_keys
    cwd=""
    [ -f /run/sbx/meta/cwd ] && cwd="$(cat /run/sbx/meta/cwd)"
    cid="$(cat /run/sbx/meta/cid)"
    umount /run/sbx/meta

    spec="$(arg sbx.spec)"
    [ -n "$spec" ] || { echo "sbx-setup: no sbx.spec= on the kernel command line" >&2; exit 1; }

    # Storage: one share per tier; each entry is grafted onto ~/<path>, parent-first
    # (the spec lists entries in that order).
    for t in $(jq -r '.tiers[]' "$spec"); do vfs "sbx-$t" "/run/sbx/tier/$t"; done
    jq -r '.entries[] | [.tier, .path] | @tsv' "$spec" |
      while IFS=$'\t' read -r tier path; do
        graft "/run/sbx/tier/$tier/$path" "$home/$path"
      done

    # Static binds (git config, capabilities.binds, extraBinds) at their target paths.
    if [ "$(jq '.binds | length' "$spec")" -gt 0 ]; then
      vfs sbx-binds /run/sbx/binds
      jq -r '.binds[] | [.index, .target] | @tsv' "$spec" |
        while IFS=$'\t' read -r index target; do
          graft "/run/sbx/binds/$index" "$target"
        done
    fi

    # The project directory, at the same absolute path as on the host.
    if [ "$(jq '.cwd' "$spec")" = true ] && [ -n "$cwd" ]; then
      mkparents "$cwd"
      case "$cwd" in
        "$home"/*) install -d -m 0755 -o "$user" -g "$group" -- "$cwd" ;;
        *) install -d -m 0755 -- "$cwd" ;;
      esac
      mount -t virtiofs -o nosuid,nodev sbx-cwd "$cwd"
    fi

    # Host services (audio, the filtered session bus) over the vsock relay: one
    # guest socket per service the app was given.
    if [ "$(jq '.relay | length' "$spec")" -gt 0 ]; then
      {
        echo "$cid"
        jq -r '.relay[] | "\(.name)=\(.path)"' "$spec"
      } > /run/sbx/relay.args
      for d in $(jq -r '.relay[].path' "$spec" | xargs -n1 dirname | sort -u); do
        install -d -m 0755 -o "$user" -g "$group" "$d"
      done
      systemctl start --no-block sbx-relay.service || true
    fi

    # Folder grants (lib/vm/grants.py): the host's allowlisted view of the home,
    # behind a root-only directory; granted folders are bound out of it by
    # sbx-grantd at their real paths.
    if [ "$(jq '.grants' "$spec")" = true ]; then
      install -d -m 0700 /run/sbx/grants
      vfs sbx-grants /run/sbx/grants/home
      printf '%s' "$cid" > /run/sbx/grants/cid
      systemctl start --no-block sbx-grantd.service || true
    fi

    # X11 apps: Xwayland on the guest's Wayland socket (guest-graphics.nix).
    if [ "$(jq '.x11' "$spec")" = true ]; then
      systemctl start --no-block sbx-xwayland.service || true
    fi
  '';
in
{
  imports = [ ./guest-graphics.nix ];

  system.stateVersion = sbxHost.stateVersion;
  networking.hostName = "sandbox-vm";

  boot = {
    kernelPackages = sbxHost.kernelPackages;
    loader.grub.enable = false;
    initrd.systemd.enable = true;
    initrd.kernelModules = [
      "virtio_pci"
      "virtiofs"
    ];
    kernelModules = [ "vmw_vsock_virtio_transport" ];
    kernelParams = [
      "console=ttyS0"
      # Reboot (= crosvm exits, the unit stops) instead of hanging on a panic.
      "panic=-1"
      # The SSH socket below is explicit; don't let systemd-ssh-generator add another.
      "systemd.ssh_auto=no"
    ];
  };

  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
    options = [
      "mode=0755"
      "size=50%"
    ];
  };
  fileSystems."/nix/store" = {
    device = "nixstore";
    fsType = "virtiofs";
    options = [ "ro" ];
    neededForBoot = true;
  };

  # The store is read-only and has no database: no nix-daemon, no local builds.
  nix.enable = false;
  documentation.enable = false;

  users = {
    mutableUsers = false;
    # Only key-based SSH as the user; there is no password to lock anyone out with.
    allowNoPasswordLogin = true;
    users.root.hashedPassword = "!";
    users.${user} = {
      isNormalUser = true;
      uid = sbxHost.uid;
      group = sbxHost.group;
      inherit home;
      createHome = true;
      # "*" (no valid password) rather than "!" (locked): sshd refuses key logins
      # for locked accounts.
      hashedPassword = "*";
      shell = pkgs.bashInteractive;
    };
    groups.${sbxHost.group}.gid = sbxHost.gid;
    users.sshd = {
      isSystemUser = true;
      group = "sshd";
      description = "SSH privilege separation user";
    };
    groups.sshd = { };
  };
  security.sudo.enable = false;

  i18n.defaultLocale = sbxHost.locale;
  time.timeZone = sbxHost.timeZone;

  environment.systemPackages = [ pkgs.kitty.terminfo ];

  # No login prompts on the consoles; the only way in is vsock SSH.
  console.enable = false;
  systemd.services."serial-getty@ttyS0".enable = false;

  networking = {
    useNetworkd = true;
    useDHCP = false;
    firewall.enable = true;
  };
  systemd.network = {
    wait-online.enable = false;
    networks."10-uplink" = {
      matchConfig.Type = "ether";
      networkConfig.DHCP = "yes";
    };
  };
  services.resolved.enable = true;

  systemd.services.sbx-setup = {
    description = "Attach the sandboxed app's storage and project directory";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    path = with pkgs; [
      coreutils
      util-linux
      jq
      systemd
      findutils
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = setup;
    };
  };

  systemd.services.sbx-relay = {
    description = "Host services for the app (vsock relay)";
    after = [ "sbx-setup.service" ];
    script = ''
      mapfile -t a < /run/sbx/relay.args
      exec ${vsockRelay}/bin/vsock-relay guest --port "''${a[0]}" "''${a[@]:1}"
    '';
    serviceConfig = {
      User = user;
      Restart = "on-failure";
      RestartSec = 1;
    };
  };

  systemd.services.sbx-grantd = {
    description = "Folder grants from the host";
    after = [ "sbx-setup.service" ];
    path = [ pkgs.util-linux ];
    script = ''
      exec ${grantsPkg}/bin/sbx-grants guest --port "$(cat /run/sbx/grants/cid)" --mount /run/sbx/grants/home \
        --home ${home} --owner ${toString sbxHost.uid}:${toString sbxHost.gid}
    '';
    serviceConfig = {
      Restart = "always";
      RestartSec = 1;
    };
  };

  # SSH over vsock, one sshd per connection. Key-only, no forwarding of any kind.
  environment.etc."ssh/sshd_config".text = ''
    HostKey /run/sbx/ssh/ssh_host_ed25519_key
    AuthorizedKeysFile /run/sbx/ssh/authorized_keys
    AllowUsers ${user}
    PermitRootLogin no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    UsePAM no
    StrictModes yes
    PermitUserEnvironment no
    AllowAgentForwarding no
    AllowTcpForwarding no
    AllowStreamLocalForwarding no
    X11Forwarding no
    PermitTunnel no
    PrintMotd no
    AcceptEnv LANG LC_* COLORTERM
  '';
  systemd.sockets.sbx-sshd = {
    description = "SSH over vsock";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "vsock::22" ];
    socketConfig.Accept = true;
  };
  systemd.services."sbx-sshd@" = {
    description = "SSH session over vsock";
    requires = [ "sbx-setup.service" ];
    after = [ "sbx-setup.service" ];
    serviceConfig = {
      ExecStart = "-${pkgs.openssh}/bin/sshd -i -f /etc/ssh/sshd_config";
      StandardInput = "socket";
      StandardError = "journal";
      KillMode = "process";
    };
  };
}
