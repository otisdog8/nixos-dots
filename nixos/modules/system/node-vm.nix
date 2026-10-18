# Cluster nodes as VMs: both sides (docs/node-vms.md).
#
# modules.system.nodeVms (the machine): a k3s node's machine runs nothing but
# its VMs, the main cluster's node and later the sensitive cluster's. Root in
# a node is root in its VM, not on the machine, so one cluster's node is no
# way into the other's. That holds only while the machine stays out of reach:
# no agent-auth hostd, no libvirt, no k3s, ssh for jrt alone (hosts/<node>-hv).
#
# The VMM is crosvm, as for the agent VM and the app VMs (lib/vm/core): each
# device in its own jailed process, the VMM unprivileged in its own
# namespaces, under the same systemd sandbox (core.hardening.vmm). No
# firmware: the guest's kernel and initrd boot directly, from its system in
# the machine's store, and the guest mounts that store read-only over
# virtio-fs (core.storeShare). So the guest has no store, bootloader or
# system of its own on disk: its disk holds only its state, and the machine's
# config builds and pins the guest's (`guest`).
#
# - Disks: whole block devices (virtio-blk, O_DIRECT, discard passed
#   through), each the guest's /dev/disk/by-id/virtio-<serial>.
# - Network: a macvtap on the LAN NIC (bridge mode), handed to crosvm as a
#   tap fd, virtio-net in crosvm's jailed device process (no vhost-net: the
#   guest's packets don't reach a host kernel driver of their own). The guest
#   is a LAN host of its own (its MAC, its DHCP lease); the machine can't
#   reach it over the LAN (macvtap doesn't hairpin to its parent), and
#   doesn't need to.
# - Console: the guest's ttyS0 goes to this unit's journal
#   (`journalctl -u node-vm-<name>`); it is output only.
# - Updates: a rebuild of the machine never restarts a guest (that would be a
#   node reboot); `sudo node-vm restart <name>` boots the new one.
# - Stop: crosvm's power button, the guest's own orderly shutdown (kubelet's
#   graceful node shutdown takes up to 60s, k3s module), then TimeoutStopSec.
#   A guest that powers off stays off; a reboot or a crash restarts the unit.
#
# modules.system.nodeVmGuest (the guest): mounts the machine's store, and
# boots with no bootloader.
{
  config,
  lib,
  options,
  pkgs,
  utils,
  ...
}:
let
  core = import ../../../lib/vm/core { inherit lib pkgs; };
  cfg = config.modules.system.nodeVms;
  guestCfg = config.modules.system.nodeVmGuest;
  smokeCfg = config.modules.system.nodeVmSmoke;

  rt = name: "/run/node-vm/${name}";
  # Prep's: which /dev/tapN is the VM's. The VMM's own unit can't tell: in
  # its network namespace, /sys/class/net holds only lo.
  netDir = name: "/run/node-vm-net/${name}";
  ns = name: "nv-${name}";
  tap = name: "nv-${name}";
  vmUser = "node-vm";

  # One user's Home Manager files, as tmpfiles rules: the directories they
  # sit in, the user's own, then a link per file into the generation.
  hmLinks =
    user: hm:
    let
      home = hm.home.homeDirectory;
      owner = "${user} ${config.users.users.${user}.group}";
      targets = map (f: lib.removePrefix "./" f.target) (
        lib.filter (f: f.enable) (lib.attrValues hm.home.file)
      );
      parents =
        t:
        let
          d = dirOf t;
        in
        if d == "." then [ ] else parents d ++ [ d ];
      # ~/.ssh is 0700, impermanence.nix's rule.
      dirs = lib.subtractLists [ ".ssh" ] (lib.unique (lib.concatMap parents targets));
    in
    map (d: "d ${home}/${d} 0755 ${owner} -") dirs
    ++ map (t: "L+ ${home}/${t} - - - - ${hm.home-files}/${t}") targets;

  disk = lib.types.submodule {
    options = {
      device = lib.mkOption {
        type = lib.types.str;
        example = "/dev/vg/node";
        description = "Block device on the machine, given to the guest whole.";
      };
      serial = lib.mkOption {
        type = lib.types.strMatching "[a-z0-9-]{1,20}";
        description = "virtio serial: the guest's /dev/disk/by-id/virtio-<serial>.";
      };
    };
  };

  vm = lib.types.submodule {
    options = {
      guest = lib.mkOption {
        type = lib.types.raw;
        description = "The guest's NixOS system (a nixosConfigurations entry).";
      };
      autostart = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Start with the machine (multi-user.target).";
      };
      memoryMiB = lib.mkOption { type = lib.types.ints.positive; };
      vcpus = lib.mkOption { type = lib.types.ints.positive; };
      mac = lib.mkOption {
        type = lib.types.strMatching "([0-9a-f]{2}:){5}[0-9a-f]{2}";
        description = "The guest NIC's MAC: what the LAN's DHCP knows it by.";
      };
      parentInterface = lib.mkOption {
        type = lib.types.str;
        description = "The machine's LAN NIC the macvtap sits on.";
      };
      disks = lib.mkOption { type = lib.types.listOf disk; };
      stopTimeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 210;
        description = "Seconds the guest gets to power off before crosvm is killed.";
      };
    };
  };

  units =
    name: v:
    let
      unit = "node-vm-${name}";
      g = v.guest.config;
      top = g.system.build.toplevel;
      devices = map (d: d.device) v.disks;
      # The VM's network namespace, nv-<name>: just lo and the macvtap. Made
      # in the host's namespace on the LAN NIC, then moved there, so the VMM
      # (which joins it, NetworkNamespacePath) can look its tap up by name, as
      # crosvm does for the MTU, and sees no other interface, address or
      # abstract socket of the host's. The move re-creates the tap's device
      # node (/dev/tap<ifindex>); its ifindex, unique on the host, stays.
      #
      # The devices and the tap are root's; prep gives exactly these to the
      # VMM's uid, at every start (udev resets the disks on change events,
      # which don't touch an fd crosvm already holds).
      prep = pkgs.writeShellScript "${unit}-prep" ''
        set -euo pipefail
        ip=${pkgs.iproute2}/bin/ip
        $ip netns del ${ns name} 2>/dev/null || true
        $ip link del ${tap name} 2>/dev/null || true
        $ip netns add ${ns name}
        $ip link add link ${v.parentInterface} name ${tap name} address ${v.mac} type macvtap mode bridge
        $ip link set ${tap name} netns ${ns name}
        $ip -n ${ns name} link set ${tap name} up
        idx=$($ip -n ${ns name} -o link show ${tap name} | cut -d: -f1)
        dev=/dev/tap$idx
        for _ in $(seq 1 50); do [ -c "$dev" ] && break; sleep 0.1; done
        chown ${vmUser}: "$dev"
        printf '%s\n' "$dev" > ${netDir name}/tap
        chown ${vmUser}: ${netDir name}/tap
        for d in ${lib.escapeShellArgs devices}; do
          chown ${vmUser}: "$(${pkgs.coreutils}/bin/readlink -f "$d")"
        done
      '';
      cleanup = pkgs.writeShellScript "${unit}-cleanup" ''
        ${pkgs.iproute2}/bin/ip -n ${ns name} link del ${tap name} 2>/dev/null || true
        ${pkgs.iproute2}/bin/ip netns del ${ns name} 2>/dev/null || true
        for d in ${lib.escapeShellArgs devices}; do
          chown root:disk "$(${pkgs.coreutils}/bin/readlink -f "$d")" 2>/dev/null || true
        done
      '';
      params = g.boot.kernelParams ++ [ "init=${top}/init" ];
      run = pkgs.writeShellScript unit ''
        set -euo pipefail
        exec 3<>"$(cat ${netDir name}/tap)"
        args=(
          run
          --name ${tap name}
          --mem size=${toString v.memoryMiB}
          --cpus num-cores=${toString v.vcpus}
          --no-usb
          --hugepages
          --serial type=stdout,hardware=serial,console=true
          -s ${rt name}/crosvm.sock
          --shared-dir "${core.storeShare}"
          ${lib.concatMapStringsSep "\n      " (
            d: ''--block "path=${d.device},id=${d.serial},o_direct=true"''
          ) v.disks}
          --net tap-fd=3,mac=${v.mac}
        )
        for p in ${lib.escapeShellArgs params}; do args+=(-p "$p"); done
        exec ${pkgs.crosvm}/bin/crosvm "''${args[@]}" \
          --initrd ${g.system.build.initialRamdisk}/${g.system.boot.loader.initrdFile} \
          ${g.boot.kernelPackages.kernel}/${g.system.boot.loader.kernelFile}
      '';
      stop = pkgs.writeShellScript "${unit}-stop" ''
        # Gone already when the guest powered itself off.
        [ -S ${rt name}/crosvm.sock ] || exit 0
        exec ${pkgs.crosvm}/bin/crosvm powerbtn ${rt name}/crosvm.sock
      '';
    in
    {
      "${unit}-prep" = {
        description = "Node VM ${name}: its macvtap and disks";
        bindsTo = [ "${unit}.service" ];
        restartIfChanged = false;
        stopIfChanged = false;
        # Not core.hardening.rootStep: `ip netns add` bind-mounts the
        # namespace at /run/netns, which must land in the host's mount
        # namespace for the VMM's unit to join it, so no option here may give
        # this unit a mount namespace of its own (ProtectSystem, PrivateTmp,
        # ProtectHome, ...). Bounded by its capabilities instead.
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = prep;
          ExecStop = cleanup;
          RuntimeDirectory = "node-vm-net/${name}";
          RuntimeDirectoryMode = "0755";
          CapabilityBoundingSet = [
            "CAP_NET_ADMIN"
            "CAP_SYS_ADMIN"
            "CAP_CHOWN"
          ];
          NoNewPrivileges = true;
          RestrictAddressFamilies = [
            "AF_NETLINK"
            "AF_UNIX"
          ];
          SystemCallArchitectures = "native";
          LockPersonality = true;
          RestrictRealtime = true;
          UMask = "0077";
        };
      };

      ${unit} = {
        description = "Node VM ${name}";
        wantedBy = lib.optional v.autostart "multi-user.target";
        requires = [ "${unit}-prep.service" ];
        after = [
          "${unit}-prep.service"
          "network-online.target"
        ];
        wants = [ "network-online.target" ];
        restartIfChanged = false;
        stopIfChanged = false;
        serviceConfig = {
          Type = "simple";
          ExecStart = run;
          ExecStop = "-${stop}";
          TimeoutStopSec = v.stopTimeout;
          KillMode = "mixed";
          Restart = "on-failure";
          RestartSec = 10;

          User = vmUser;
          Group = vmUser;
          SystemCallFilter = core.hardening.jailedSyscallFilter;
          RuntimeDirectory = "node-vm/${name}";
          RuntimeDirectoryMode = "0700";
          ReadWritePaths = [ (rt name) ];
          PrivatePIDs = true;
          DeviceAllow = [
            "/dev/kvm rw"
            "char-macvtap rw"
          ]
          ++ map (d: "${d} rw") devices;
          # The guest's memory is shmem charged here, and once its page cache
          # has touched all of it (a day on arquitens), it is all resident and
          # none reclaimable (no swap). Above it: crosvm's own, mostly page
          # tables, which every sandboxed device process keeps for the guest
          # memory it touches, ~memoryMiB/512 each at 4K pages. A flat 512M
          # was short of that (530M at the OOM, 2026-10-18); huge pages
          # (--hugepages) make it small, but fall back to 4K when memory is
          # fragmented, so the margin assumes they did.
          MemoryMax = "${toString (v.memoryMiB + 512 + v.memoryMiB / 32)}M";
        }
        // core.hardening.vmm
        // core.hostView { inherit (config) fileSystems; }
        // {
          # The VM's own namespace (prep), in place of a private one: the same
          # nothing of the host's, plus its tap, which crosvm looks up by name
          # with an AF_INET socket's ioctl (IPAddressDeny still stops any IP
          # traffic of the VMM's own).
          PrivateNetwork = false;
          NetworkNamespacePath = "/run/netns/${ns name}";
          RestrictAddressFamilies = core.hardening.vmm.RestrictAddressFamilies ++ [
            "AF_INET"
            "AF_INET6"
          ];
        };
      };
    };

  cli = pkgs.writeShellScriptBin "node-vm" ''
    set -euo pipefail
    case "''${1:-list}" in
      list) exec ${pkgs.systemd}/bin/systemctl list-units --no-legend --plain 'node-vm-*.service' ;;
      restart|start|stop)
        [ -n "''${2:-}" ] || { echo "usage: node-vm $1 NAME" >&2; exit 2; }
        exec ${pkgs.systemd}/bin/systemctl "$1" "node-vm-$2.service" ;;
      log)
        [ -n "''${2:-}" ] || { echo "usage: node-vm log NAME" >&2; exit 2; }
        exec ${pkgs.systemd}/bin/journalctl -u "node-vm-$2.service" -f ;;
      *) echo "usage: node-vm [list | start|stop|restart NAME | log NAME]" >&2; exit 2 ;;
    esac
  '';
in
{
  options.modules.system.nodeVms = lib.mkOption {
    type = lib.types.attrsOf vm;
    default = { };
    description = "Cluster node VMs this machine runs, by name (nv-<name> is the macvtap).";
  };

  options.modules.system.nodeVmGuest = {
    enable = lib.mkEnableOption "running as a node VM (modules.system.nodeVms)";
  };

  # A throwaway VM through the very same unit, to prove the path on a machine
  # before anything depends on it: macvtap fd, the VMM's sandbox, the shared
  # store, direct boot, a DHCP lease. No disks; it reports in its console and
  # powers off: `sudo systemctl start node-vm-smoke; node-vm log smoke`, and
  # look for NODE-VM-SMOKE.
  options.modules.system.nodeVmSmoke = {
    enable = lib.mkEnableOption "the node VM smoke test (node-vm-smoke, started by hand)";
    parentInterface = lib.mkOption {
      type = lib.types.str;
      description = "The machine's LAN NIC.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf smokeCfg.enable {
      modules.system.nodeVms.smoke = {
        guest = import "${pkgs.path}/nixos/lib/eval-config.nix" {
          system = null;
          modules = [
            ./node-vm.nix
            {
              nixpkgs.pkgs = pkgs;
              modules.system.nodeVmGuest.enable = true;
              networking.hostName = "node-vm-smoke";
              fileSystems."/" = {
                device = "none";
                fsType = "tmpfs";
                options = [ "mode=0755" ];
              };
              networking.useDHCP = true;
              systemd.services.node-vm-smoke = {
                wantedBy = [ "multi-user.target" ];
                wants = [ "network-online.target" ];
                after = [ "network-online.target" ];
                path = [
                  pkgs.iproute2
                  pkgs.iputils
                  pkgs.gawk
                  pkgs.systemd
                ];
                serviceConfig = {
                  Type = "oneshot";
                  StandardOutput = "journal+console";
                };
                script = ''
                  ip -br addr
                  test -e ${pkgs.hello}/bin/hello && echo "store: shared"
                  gw=$(ip -4 route show default | awk '{print $3; exit}')
                  if [ -n "$gw" ] && ping -c 3 -W 2 "$gw"; then
                    echo "NODE-VM-SMOKE: OK (lease, gateway $gw reachable)"
                  else
                    echo "NODE-VM-SMOKE: FAIL (no lease, or the gateway doesn't answer)"
                  fi
                  systemctl poweroff
                '';
              };
              system.stateVersion = "24.05";
            }
          ];
        };
        autostart = false;
        memoryMiB = 1024;
        vcpus = 1;
        mac = "02:00:00:00:5a:01";
        inherit (smokeCfg) parentInterface;
        disks = [ ];
        stopTimeout = 30;
      };
      # A test: one failure is the answer, not a reason to try again.
      systemd.services.node-vm-smoke.serviceConfig.Restart = lib.mkForce "no";
    })

    (lib.mkIf (cfg != { }) {
      assertions = lib.mapAttrsToList (name: _: {
        assertion = builtins.stringLength (tap name) <= 15;
        message = "modules.system.nodeVms.${name}: the name is too long for its macvtap (nv-<name>, 15 characters).";
      }) cfg;

      boot.kernelModules = [ "macvtap" ];

      # Huge pages for guest memory (crosvm --hugepages), which is a memfd:
      # shmem, whose THP is off by default. advise: only where asked.
      systemd.tmpfiles.rules = [
        "w /sys/kernel/mm/transparent_hugepage/shmem_enabled - - - - advise"
      ];

      users.users.${vmUser} = {
        isSystemUser = true;
        group = vmUser;
        description = "cluster node VMs (crosvm)";
      };
      users.groups.${vmUser} = { };

      environment.systemPackages = [ cli ];

      systemd.services = lib.mkMerge (lib.mapAttrsToList units cfg);
    })

    (lib.mkIf guestCfg.enable {
      # The machine's store, read-only (core.storeShare's tag). Nothing here
      # builds: the machine builds this system and boots it.
      fileSystems."/nix/store" = {
        device = "nixstore";
        fsType = "virtiofs";
        options = [ "ro" ];
        neededForBoot = true;
      };
      boot.initrd.availableKernelModules = [
        "virtiofs"
        "virtio_blk"
        "virtio_net"
        "virtio_pci"
        "virtio_console"
      ];
      # Booted by crosvm directly (kernel, initrd, init= from the machine).
      boot.loader.grub.enable = false;
      boot.loader.systemd-boot.enable = lib.mkForce false;
      # The hosts get it from secureboot.nix; the impermanence rollback is an
      # initrd unit.
      boot.initrd.systemd.enable = true;
      boot.kernelParams = [
        "console=ttyS0,115200"
        # A panic restarts the VM (crosvm exits, the unit restarts).
        "panic=-1"
      ];
      # No nix here: the store is the machine's and read-only (and its GC is
      # the machine's, which keeps this system: the machine's config holds it).
      nix.enable = false;
      nix.gc.automatic = lib.mkForce false;
      nix.optimise.automatic = lib.mkForce false;
    })

    # Home Manager's activation needs nix (nix-build's sanity check, its
    # generation's GC root), and a guest has none. The guest links the
    # generation's files instead, with tmpfiles at boot: home is on the
    # rolled-back root, and a guest update is a reboot, so each boot is a
    # fresh activation. No activation scripts run (the ssh config's copy, any
    # onChange): ~/.ssh/config stays a link into the read-only store. The
    # packages come anyway (useUserPackages). (Where the option exists: the
    # smoke guest has no Home Manager.)
    (lib.optionalAttrs (options ? home-manager) (
      lib.mkIf guestCfg.enable {
        systemd.services = lib.mapAttrs' (
          user: _: lib.nameValuePair "home-manager-${utils.escapeSystemdPath user}" { enable = false; }
        ) config.home-manager.users;
        systemd.tmpfiles.rules = lib.concatLists (lib.mapAttrsToList hmLinks config.home-manager.users);
      }
    ))
  ];
}
