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
  dbusProxy = sbxHost.dbusProxy;
  grantsPkg = import ./grants.nix pkgs;
  graft = pkgs.writeScriptBin "sbx-graft" (
    "#!${pkgs.python3}/bin/python3 -IS\n" + builtins.readFile ./graft.py
  );
  fidoGuest = pkgs.writeScriptBin "sbx-fido-guest" (
    "#!${pkgs.python3}/bin/python3 -IS\n" + builtins.readFile ./fido-guest.py
  );
  clipGuest = pkgs.writeScriptBin "sbx-clip-guest" (
    "#!${pkgs.python3}/bin/python3 -IS\n" + builtins.readFile ./clip-guest.py
  );
  userRuntimeDir = "/run/user/${toString sbxHost.uid}";

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

    # Bind sources onto targets, one "MODE<TAB>SOURCE<TAB>TARGET" line each on
    # stdin (lib/vm/graft.py): the paths are walked without following the app's
    # symlinks, missing targets and parents made (the user's under $home).
    graft() { ${graft}/bin/sbx-graft "$home" "$user" "$group"; }

    vfs() { install -d -m 0755 "$2"; mount -t virtiofs -o "nosuid,nodev''${3:+,$3}" "$1" "$2"; }

    # Per-launch metadata: SSH keys and (per-project VMs) the working directory.
    vfs sbx-meta /run/sbx/meta ro
    install -d -m 0755 /run/sbx/ssh
    install -m 0600 /run/sbx/meta/ssh_host_ed25519_key /run/sbx/ssh/ssh_host_ed25519_key
    install -m 0644 /run/sbx/meta/authorized_keys /run/sbx/ssh/authorized_keys
    if [ -f /run/sbx/meta/root_authorized_keys ]; then
      install -m 0644 /run/sbx/meta/root_authorized_keys /run/sbx/ssh/root_authorized_keys
    fi
    # A restricted VM's app environment (instance.nix forcedCommand).
    if [ -f /run/sbx/meta/launch.env ]; then
      install -m 0644 /run/sbx/meta/launch.env /run/sbx/launch.env
    fi
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
        printf 'rw\t%s\t%s\n' "/run/sbx/tier/$tier/$path" "$home/$path"
      done | graft

    # Static binds (git config, capabilities.binds, extraBinds) at their target paths.
    if [ "$(jq '.binds | length' "$spec")" -gt 0 ]; then
      vfs sbx-binds /run/sbx/binds
      jq -r '.binds[] | [.index, .target] | @tsv' "$spec" |
        while IFS=$'\t' read -r index target; do
          printf 'rw\t%s\t%s\n' "/run/sbx/binds/$index" "$target"
        done | graft
    fi

    # The project directory, at the same absolute path as on the host: mounted
    # in a root-only place first, then grafted (its path may lead through the
    # app's storage).
    if [ "$(jq '.cwd' "$spec")" = true ] && [ -n "$cwd" ]; then
      install -d -m 0700 /run/sbx/stage
      vfs sbx-cwd /run/sbx/stage/cwd
      printf 'rw\t%s\t%s\n' /run/sbx/stage/cwd "$cwd" | graft
    fi

    # Host services (audio, the filtered session bus) over the vsock relay: one
    # guest socket per service the app was given. The relay runs as the user, so
    # each socket's directory is the user's — but never /run/sbx itself, which
    # holds root's and sbx-capture's state (its owner could rename those away
    # and plant its own): a socket meant directly in it (the broker's) listens
    # in /run/sbx/relay, behind a root-owned link at the usual path.
    if [ "$(jq '.relay | length' "$spec")" -gt 0 ]; then
      echo "$cid" > /run/sbx/relay.args
      jq -r '.relay[] | [.name, .path] | @tsv' "$spec" |
        while IFS=$'\t' read -r name path; do
          if [ "$(dirname -- "$path")" = /run/sbx ]; then
            ln -sfn -- "relay/$(basename -- "$path")" "$path"
            path="/run/sbx/relay/$(basename -- "$path")"
          fi
          install -d -m 0755 -o "$user" -g "$group" -- "$(dirname -- "$path")"
          printf '%s=%s\n' "$name" "$path" >> /run/sbx/relay.args
        done
      systemctl start --no-block sbx-relay.service || true
      if jq -e '.relay | any(.name == "dbus" or .name == "capture-dbus")' "$spec" >/dev/null; then
        if jq -e '.capture' "$spec" >/dev/null; then
          touch /run/sbx/capture-enabled
          systemctl start --no-block sbx-capture-broker.service
        fi
        systemctl start --no-block sbx-dbus-proxy.service
      fi
    fi

    # Folder grants (lib/vm/grants.py): the host's view of what was granted,
    # behind a root-only directory; granted folders are bound out of it by
    # sbx-grantd at their real paths.
    if [ "$(jq '.grants' "$spec")" = true ]; then
      install -d -m 0700 /run/sbx/grants
      vfs sbx-grants /run/sbx/grants/home
      printf '%s' "$cid" > /run/sbx/grants/cid
      systemctl start --no-block sbx-grantd.service || true
    fi

    # Portal documents (file-chooser results): the app's by-app view of the host's
    # document portal, where flatpak apps find it.
    if [ "$(jq '.docs' "$spec")" = true ]; then
      rtd=/run/user/$(id -u "$user")
      install -d -m 0700 -o "$user" -g "$group" "$rtd"
      install -d -m 0700 -o "$user" -g "$group" "$rtd/doc"
      mount -t virtiofs -o nosuid,nodev sbx-docs "$rtd/doc" ||
        echo "sbx-setup: no document share (file choosers won't work)" >&2
    fi

    # Security keys: a virtual FIDO device relayed to the host's key (fido-guest.py).
    if [ "$(jq '.fido' "$spec")" = true ]; then
      systemctl start --no-block sbx-fido.service || true
    fi

    # Other modules' read-only files (sandbox.vm.guestBinds), e.g. native-messaging
    # manifests: an empty mount point of the source's type, then a bind.
    jq -r '.guestBinds[] | ["ro", .source, .target] | @tsv' "$spec" | graft ||
      echo "sbx-setup: could not bind every guestBinds entry" >&2

    # Other modules' long-running helpers (sandbox.vm.guestServices), as the user
    # (or as root, for the ones that ask).
    jq -c '.services[]' "$spec" | while read -r sv; do
      name="$(jq -r .name <<<"$sv")"
      grp="$(jq -r '.group // empty' <<<"$sv")"
      opts=(--unit="sbx-svc-$name" -p Restart=on-failure -p RestartSec=2 --no-block)
      [ "$(jq -r '.root // false' <<<"$sv")" = true ] || opts+=(--uid="$user")
      if [ -n "$grp" ]; then
        getent group "$grp" >/dev/null || groupadd -r "$grp"
        opts+=(--gid="$grp")
      fi
      mapfile -t env < <(jq -r '.env[]' <<<"$sv")
      for e in "''${env[@]}"; do opts+=(-E "$e"); done
      mapfile -t argv < <(jq -r '.argv[]' <<<"$sv")
      systemd-run "''${opts[@]}" -- "''${argv[@]}" ||
        echo "sbx-setup: could not start $name" >&2
    done

    # GPU and display, per VM (guest-graphics.nix): virtio-nvgpu only in the VMs
    # given the device, cross-domain for the other GUI VMs.
    if [ "$(jq '.gpu' "$spec")" = true ]; then
      modprobe virtio_gpu_nv || echo "sbx-setup: no virtio-nvgpu module" >&2
    fi
    case "$(jq -r '.display // empty' "$spec")" in
      nvgpu)
        echo "WAYLAND_DISPLAY=/run/sbx/wl/wayland-0" > /run/sbx/display.env
        systemctl start --no-block sbx-wayland-nvgpu.service || true ;;
      cross-domain)
        echo "WAYLAND_DISPLAY=wayland-0" > /run/sbx/display.env
        systemctl start --no-block sbx-wayland-cross-domain.service || true ;;
    esac

    # Data-control copies to the host's clipboard (clip-guest.py), in front of
    # the display just chosen.
    if [ "$(jq '.clip' "$spec")" = true ]; then
      systemctl start --no-block sbx-clip.service || true
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
    # Only key-based SSH (the user, and root with root's own key); there is no
    # password to lock anyone out with.
    allowNoPasswordLogin = true;
    # "*", not "!": root logs in with its own key (`sudo sandbox-vm root` on the
    # host), and sshd refuses key logins for locked accounts.
    users.root.hashedPassword = "*";
    users.${user} = {
      isNormalUser = true;
      uid = sbxHost.uid;
      group = sbxHost.group;
      # SSH diagnostics need the guest service logs (capture, D-Bus, graphics),
      # without root (whose key only root on the host has). This VM's journal only, but
      # all of it — the guest kernel's log and every guest service's, root's
      # too — and to the apps as well, which run as this user. Nothing logged
      # there may be secret from the apps (capture tokens are never logged).
      extraGroups = [ "systemd-journal" ];
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
      shadow
      glibc.getent
      kmod
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

  # Accept Unix FD negotiation locally, but keep the host connection behind
  # its existing policy filter and FD-free vsock transport.
  systemd.services.sbx-dbus-proxy = {
    description = "Guest D-Bus proxy to the filtered host session bus";
    requires = [ "sbx-relay.service" ];
    after = [
      "sbx-setup.service"
      "sbx-relay.service"
    ];
    script = ''
      # The relay binds its sockets after systemd considers it started. The
      # capture broker is dialled per share, not waited for: the app's bus
      # must not depend on it (a share then fails, and says so).
      for ((attempt = 0; attempt < 100; attempt++)); do
        if [ -S /run/sbx/bus/transport.sock ]; then
          if [ -f /run/sbx/capture-enabled ]; then
            exec ${dbusProxy}/bin/vm-dbus-capture-proxy --role guest \
              --listen /run/sbx/bus/bus --upstream /run/sbx/bus/transport.sock \
              --broker /run/sbx/capture/broker.sock
          fi
          exec ${dbusProxy}/bin/vm-dbus-proxy \
            --listen /run/sbx/bus/bus \
            --upstream /run/sbx/bus/transport.sock
        fi
        ${pkgs.coreutils}/bin/sleep 0.1
      done
      echo "sbx-dbus-proxy: host bus transport socket did not appear" >&2
      exit 1
    '';
    serviceConfig = {
      User = user;
      ExecStartPre = "${pkgs.coreutils}/bin/rm -f /run/sbx/bus/bus";
      Restart = "on-failure";
      RestartSec = 1;
    };
  };

  users.groups.sbx-capture = { };
  users.groups.nvgpu-capture = { };
  users.users.sbx-capture = {
    isSystemUser = true;
    group = "sbx-capture";
    # The capture node and the render node its imports are opened against;
    # not video (card nodes, and cameras passed through to the VM).
    extraGroups = [
      "nvgpu-capture"
      "render"
    ];
  };
  # Created even in non-capture guests, but the service starts only when the
  # instance spec enables capture. Apps cannot inspect per-session runtimes.
  systemd.tmpfiles.rules = [ "d /run/sbx/capture 0711 sbx-capture sbx-capture -" ];
  systemd.services.sbx-capture-broker = {
    description = "Private PipeWire publishers for approved host screen shares";
    after = [ "sbx-setup.service" ];
    serviceConfig = {
      User = "sbx-capture";
      Group = "sbx-capture";
      ExecStartPre = "${pkgs.coreutils}/bin/rm -f /run/sbx/capture/broker.sock";
      ExecStart =
        "${dbusProxy}/bin/vm-capture-broker --role guest"
        + " --listen /run/sbx/capture/broker.sock --allowed-uid ${toString sbxHost.uid}"
        + " --runtime-dir /run/sbx/capture --worker ${dbusProxy}/bin/vm-capture"
        + " --pipewire ${pkgs.pipewire}/bin/pipewire --wireplumber ${pkgs.wireplumber}/bin/wireplumber";
      Restart = "on-failure";
      RestartSec = 1;
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ "/run/sbx/capture" ];
      PrivateTmp = true;
      PrivateNetwork = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      LockPersonality = true;
      RestrictSUIDSGID = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
      # Its publishers hold every live share's tokens: no core dumps.
      LimitCORE = 0;
    };
  };

  # The apps' Wayland socket in a VM with sandbox.vm.clipboard: everything
  # passes to the display proxy (WAYLAND_DISPLAY, display.env) except the
  # data-control protocols, answered here and sent to the host's broker.
  systemd.services.sbx-clip = {
    description = "Data-control copies to the host's clipboard";
    after = [
      "sbx-setup.service"
      "sbx-wayland-nvgpu.service"
      "sbx-wayland-cross-domain.service"
    ];
    environment.XDG_RUNTIME_DIR = userRuntimeDir;
    serviceConfig = {
      EnvironmentFile = "/run/sbx/display.env";
      User = sbxHost.user;
      ExecStart = pkgs.writeShellScript "sbx-clip" ''
        case "$WAYLAND_DISPLAY" in /*) up="$WAYLAND_DISPLAY" ;; *) up="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ;; esac
        exec ${clipGuest}/bin/sbx-clip-guest --listen "$XDG_RUNTIME_DIR/wayland-clip" --upstream "$up" --broker /run/sbx/broker.sock
      '';
      Restart = "always";
      RestartSec = 1;
    };
  };

  systemd.services.sbx-fido = {
    description = "Security key from the host (virtual FIDO device)";
    after = [
      "sbx-setup.service"
      "systemd-udevd.service"
    ];
    serviceConfig = {
      ExecStartPre = "${pkgs.kmod}/bin/modprobe uhid";
      ExecStart = "${fidoGuest}/bin/sbx-fido-guest --broker /run/sbx/broker.sock";
      Restart = "always";
      RestartSec = 2;
    };
  };
  # No logind seat session over SSH, so uaccess never applies: the virtual key
  # (systemd's fido_id tags it) belongs to the user outright.
  services.udev.extraRules = ''
    SUBSYSTEM=="hidraw", ENV{ID_FIDO_TOKEN}=="1", OWNER="${user}", MODE="0600"
    KERNEL=="ntsync", OWNER="${user}", MODE="0600"
  '';

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
    AllowUsers ${user} root
    PermitRootLogin prohibit-password
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
    # Root's key lives only in root's directory on the host; the user's key (in
    # the file above) never admits root.
    Match User root
      AuthorizedKeysFile /run/sbx/ssh/root_authorized_keys
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
