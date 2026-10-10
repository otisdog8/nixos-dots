# The agent VM's guest (nixos/modules/system/agent-vm.nix): one long-running
# NixOS system per host where orchestrated, headless agents work. agent-auth's
# sandboxd (its nixosModules.sandboxd, through modules.agentVm.guestModules)
# adds the agents; this file is the machine underneath.
#
# Unlike the app guest (guest.nix), which is disposable and mirrors one user:
#   - / is a tmpfs, rebuilt from this configuration on every boot (as on the
#     hosts, impermanence-style); only what's listed under `persisted` below
#     lives on the data disk, /persist: a btrfs filesystem on a virtio-blk
#     disk (formatted on first boot). So projects, agent homes, scratchpads,
#     the store database and logs survive VM restarts, and nothing else does —
#     whatever a compromised guest root drops into /etc or /usr is gone at the
#     next boot. (Not a complete answer to persistence: guest root can still
#     write the store's upper layer.) btrfs rather than ext4: compression and
#     checksums inside the image (the host keeps the image nodatacow), and
#     subvolumes per project for cheap snapshots and reflink copies;
#   - /nix/store is writable: the host's store (virtio-fs, read-only) under an
#     overlay whose upper layer is on /persist, with a nix-daemon, so agents
#     can `nix develop` and build. The guest system's own closure is registered
#     in the store database at boot (its registration comes from the host on
#     the kernel command line: the guest can't compute its own closure);
#   - no display, audio, D-Bus relay or per-app wiring;
#   - root logs in over vsock SSH with the per-boot key the host's prep unit
#     generates (the only way in; operators on the host reach it through
#     `agent-vm ssh`).
{
  config,
  lib,
  pkgs,
  utils,
  agentVmHost,
  ...
}:
let
  # Directories kept on /persist, bound back in place in the initrd (so they're
  # there before anything in stage 2 starts).
  persisted = [
    "/var/lib"
    "/nix/var"
    "/var/log"
  ];
  # Their initrd mount units (the system is mounted at /sysroot there).
  persistedMounts = map (d: "${utils.escapeSystemdPath "/sysroot${d}"}.mount") persisted;
  # Kernel command line value of `key=`.
  cmdlineArg = key: ''
    for w in $(cat /proc/cmdline); do
      case "$w" in ${key}=*) printf '%s' "''${w#${key}=}"; break ;; esac
    done
  '';
in
{
  system.stateVersion = agentVmHost.stateVersion;
  networking.hostName = "agent-vm";

  boot = {
    # Same kernel as the host: nothing extra to build, and it has virtio-fs/vsock.
    kernelPackages = agentVmHost.kernelPackages;
    loader.grub.enable = false;
    initrd.systemd.enable = true;
    initrd.kernelModules = [
      "virtio_pci"
      "virtio_blk"
      "virtiofs"
      "overlay"
    ];
    initrd.supportedFilesystems = [ "btrfs" ];
    kernelModules = [ "vmw_vsock_virtio_transport" ];
    kernelParams = [
      "console=ttyS0"
      # Reboot (= crosvm exits, the unit restarts) instead of hanging on a panic.
      "panic=-1"
      # The SSH socket below is explicit; don't let systemd-ssh-generator add another.
      "systemd.ssh_auto=no"
    ];
    tmp.cleanOnBoot = true;
  };

  fileSystems = {
    "/" = {
      device = "none";
      fsType = "tmpfs";
      options = [
        "mode=0755"
        "size=25%"
      ];
    };
    "/persist" = {
      device = "/dev/vda";
      fsType = "btrfs";
      autoFormat = true;
      # discard=async: freed blocks go back to the host (the image is sparse).
      options = [
        "compress=zstd"
        "noatime"
        "discard=async"
      ];
      neededForBoot = true;
    };
    "/nix/.ro-store" = {
      device = "nixstore";
      fsType = "virtiofs";
      options = [ "ro" ];
      neededForBoot = true;
    };
    "/nix/store" = {
      overlay = {
        lowerdir = [ "/nix/.ro-store" ];
        upperdir = "/persist/nix/store-upper";
        workdir = "/persist/nix/store-work";
      };
      neededForBoot = true;
    };
  }
  // lib.genAttrs persisted (dir: {
    device = "/persist${dir}";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/persist" ];
    neededForBoot = true;
  })
  // {
    # Per-boot files from the host: the SSH host key and the operators' key.
    "/run/agent-vm/meta" = {
      device = "sbx-meta";
      fsType = "virtiofs";
      options = [
        "ro"
        "nofail"
      ];
    };
  };

  # A fresh disk has no source directories for the binds above; make them in
  # the initrd, between mounting /persist and binding.
  boot.initrd.systemd.services.agent-vm-persist-dirs = {
    description = "Create the persisted directories on /persist";
    after = [ "sysroot-persist.mount" ];
    requires = [ "sysroot-persist.mount" ];
    before = persistedMounts;
    requiredBy = persistedMounts;
    unitConfig.DefaultDependencies = false;
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p ${lib.concatMapStringsSep " " (d: "/sysroot/persist${d}") persisted}
    '';
  };

  # Stable across boots (the root is a tmpfs), so the persisted journal stays
  # one machine's.
  environment.etc.machine-id.text = "${builtins.substring 0 32 (builtins.hashString "sha256" "agent-vm-${agentVmHost.hostName}")}\n";
  services.journald.settings.Journal.Storage = "persistent";

  nix = {
    enable = true;
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      # Sandboxed builds; only root may change settings or add substituters.
      sandbox = true;
      trusted-users = [ "root" ];
      substituters = agentVmHost.substituters;
      trusted-public-keys = agentVmHost.trustedPublicKeys;
    };
    # The system closure lives in the host's store: a guest GC must never
    # whiteout what the running system needs (it is rooted at
    # /run/current-system), and nothing else here is worth collecting on a timer.
    gc.automatic = false;
  };

  # Paths present in the lower (host) store but not in this guest's database
  # would be treated as invalid and fetched again; register the system's own.
  # And the other way round: the host's GC removes paths an older guest system
  # registered (or a build here found in the lower store), which the database
  # would keep calling valid, so nix would neither fetch nor build them again.
  # `nix-store --verify` (no content check) drops every registered path that is
  # gone; one a path built here still refers to stays (reported) until
  # `nix-store --verify --repair` fetches it again.
  systemd.services.agent-vm-register-store = {
    description = "Register the guest system's closure in the nix store database";
    wantedBy = [ "multi-user.target" ];
    before = [ "nix-daemon.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      reg="$(${cmdlineArg "agentvm.registration"})"
      stamp=/nix/var/nix/agent-vm-registered
      if [ -z "$reg" ] || [ ! -f "$reg" ]; then
        echo "no agentvm.registration on the kernel command line; skipping" >&2
      elif [ "$(cat "$stamp" 2>/dev/null)" != "$reg" ]; then
        ${config.nix.package}/bin/nix-store --load-db < "$reg"
        printf '%s' "$reg" > "$stamp"
      fi
      ${config.nix.package}/bin/nix-store --verify ||
        echo "some registered paths are gone but still referenced; nix-store --verify --repair fetches them" >&2
    '';
  };

  users = {
    mutableUsers = false;
    allowNoPasswordLogin = true;
    # "*", not "!": the only way in is root's key over vsock SSH, and sshd
    # refuses key logins for locked accounts.
    users.root.hashedPassword = "*";
    # sshd is run by hand (agent-vm-sshd@), not services.openssh, so nothing
    # else creates its privilege separation user.
    users.sshd = {
      isSystemUser = true;
      group = "sshd";
      description = "SSH privilege separation user";
    };
    groups.sshd = { };
  };
  security.sudo.enable = false;
  # Project users are added at run time by sandboxd as userdb records, kept on
  # the persisted /var/lib (/etc is rebuilt every boot).
  environment.etc.userdb.source = "/var/lib/userdb";
  systemd.tmpfiles.rules = [ "d /var/lib/userdb 0755 root root -" ];
  services.userdbd = {
    enable = true;
    # The nixbld users' uids are above 1000, so userdb lists them as regular
    # users; that matters only to systemd-homed's first-boot flow, unused here.
    silenceHighSystemUsers = true;
  };

  i18n.defaultLocale = agentVmHost.locale;
  time.timeZone = agentVmHost.timeZone;
  documentation.enable = false;
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

  # sshd can't use the meta share's files directly (they're owned by the VMM's
  # host uid), so copy them root-owned into /run.
  systemd.services.agent-vm-ssh-keys = {
    description = "Install the host-provided SSH keys";
    after = [ "run-agent\\x2dvm-meta.mount" ];
    requires = [ "run-agent\\x2dvm-meta.mount" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -d -m 0700 /run/agent-vm/ssh
      install -m 0600 /run/agent-vm/meta/ssh_host_ed25519_key /run/agent-vm/ssh/
      install -m 0600 /run/agent-vm/meta/authorized_keys /run/agent-vm/ssh/
    '';
    path = [ pkgs.coreutils ];
  };
  environment.etc."ssh/sshd_config".text = ''
    HostKey /run/agent-vm/ssh/ssh_host_ed25519_key
    AuthorizedKeysFile /run/agent-vm/ssh/authorized_keys
    AllowUsers root
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
  '';
  systemd.sockets.agent-vm-sshd = {
    description = "SSH over vsock";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "vsock::22" ];
    socketConfig.Accept = true;
  };
  systemd.services."agent-vm-sshd@" = {
    description = "SSH session over vsock";
    requires = [ "agent-vm-ssh-keys.service" ];
    after = [ "agent-vm-ssh-keys.service" ];
    serviceConfig = {
      ExecStart = "-${pkgs.openssh}/bin/sshd -i -f /etc/ssh/sshd_config";
      StandardInput = "socket";
      StandardError = "journal";
      KillMode = "process";
    };
  };
}
