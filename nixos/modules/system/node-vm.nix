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
# namespaces, under the same systemd sandbox (core.hardening.vmm), and each
# VM's under a uid of its own (`vmUser`), so a VMM taken over through its
# guest has no hold on another VM's socket, tap or disks. No
# firmware: the guest's kernel and initrd boot directly, from its system in
# the machine's store, and the guest mounts that store read-only over
# virtio-fs (core.storeShare). So the guest has no store, bootloader or
# system of its own on disk: its disk holds only its state, and the machine's
# config builds and pins the guest's (`guest`).
#
# - Disks: whole block devices (virtio-blk, O_DIRECT, discard passed
#   through), each the guest's /dev/disk/by-id/virtio-<serial>.
# - Network: a macvtap on the LAN NIC (bridge mode), handed to crosvm as a
#   tap fd. The guest is a LAN host of its own (its MAC, its DHCP lease); the
#   machine can't reach it over the LAN (macvtap doesn't hairpin to its
#   parent), and doesn't need to. The packets move in the host kernel
#   (vhost-net, `vhostNet`): crosvm's jailed virtio-net moved each one with a
#   syscall of its own, and small ones (WireGuard's, ~1.3 KB: the node's
#   whole tailnet, so Cilium's tunnel and Ceph) capped the tailnet at
#   ~85 MB/s. The price: the guest's rings are read by a host kernel driver,
#   not by an unprivileged, seccomp-jailed process, so a guest kernel exploit
#   has the host's vhost code to aim at. The macvtap's queue
#   (`tapQueueLength`) rides out stalls either way, and the guest gets
#   mergeable RX buffers (`mrg-rxbuf`): 256 packets' room in its ring
#   instead of ~13 64K buffers.
# - Console: the guest's ttyS0 goes to this unit's journal
#   (`journalctl -u node-vm-<name>`); it is output only.
# - Updates: a rebuild of the machine never restarts a guest (that would be a
#   node reboot); `sudo node-vm restart <name>` boots the new one.
# - Stop: crosvm's power button, the guest's own orderly shutdown (kubelet's
#   graceful node shutdown takes up to 60s, k3s module), then TimeoutStopSec.
#   A guest that powers off stays off; a reboot or a crash restarts the unit:
#   crosvm's --extended-status tells them apart (0 a power-off; 32 a reset,
#   which a guest's reboot, panic=-1 or watchdog is; 33/34/36 a crash).
#   Without it crosvm exits 0 for a reset too, and a node that rebooted
#   stayed off (carrack, 2026-10-22: softdog reset it, 11 hours down).
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
  pinned = lib.concatLists (lib.mapAttrsToList (_: v: lib.optionals (v.pinCpus != null) v.pinCpus) cfg);
  smokeCfg = config.modules.system.nodeVmSmoke;

  rt = name: "/run/node-vm/${name}";
  # Prep's: which /dev/tapN is the VM's. The VMM's own unit can't tell: in
  # its network namespace, /sys/class/net holds only lo.
  netDir = name: "/run/node-vm-net/${name}";
  ns = name: "nv-${name}";
  tap = name: "nv-${name}";
  # Each VM's VMM runs as a uid (and group) of its own: what one VM's
  # crosvm can reach (its runtime dir and control socket, 0700; its tap
  # node, 0600; its disks) is no other VM's. Not lib/vm/core's vmUserName
  # (sbx-vm-<name>, the app VMs'). At most 20 characters: the name fits a
  # macvtap's (nv-<name>, 15).
  vmUser = name: "node-vm-${name}";

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
      pinCpus = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.ints.unsigned);
        default = null;
        example = [ 6 7 8 9 10 11 12 13 14 15 ];
        description = ''
          Host CPUs to pin the vCPUs to, one each (vCPU i on pinCpus[i]), and to
          isolate from everything else on the machine (isolcpus, nohz_full,
          rcu_nocbs): a woken vCPU then finds its CPU idle instead of queueing
          behind other threads. Keep the machine's IRQs off them too
          (irqaffinity= in the host's kernel parameters). Pinning without the
          isolation made a node VM stall (2026-10-24).
        '';
      };
      coreScheduling = lib.mkOption {
        type = lib.types.enum [ "vm" "vcpu" "off" ];
        default = "vm";
        description = ''
          crosvm's core scheduling, which keeps the vCPUs from sharing a physical
          core with other threads (SMT side channels). "vm": all of the VM's
          vCPUs share one cookie, so they may run on sibling threads together but
          nothing outside the VM runs next to them. "vcpu" (crosvm's own default):
          a cookie per vCPU, so no two vCPUs share a core either; at most one
          vCPU per core runs at a time, which with vCPUs pinned to sibling
          threads left the guest too slow to boot (2026-10-25) and without
          pinning shows up as steal. "off": no core scheduling.
        '';
      };
      mac = lib.mkOption {
        type = lib.types.strMatching "([0-9a-f]{2}:){5}[0-9a-f]{2}";
        description = "The guest NIC's MAC: what the LAN's DHCP knows it by.";
      };
      parentInterface = lib.mkOption {
        type = lib.types.str;
        description = "The machine's LAN NIC the macvtap sits on.";
      };
      tapQueueLength = lib.mkOption {
        type = lib.types.ints.positive;
        default = 4096;
        description = ''
          Packets the macvtap holds for crosvm to read (its txqueuelen; the
          kernel's default is 500). At 500 carrack's dropped 2% of what it
          received, mostly Tailscale's small packets, when crosvm fell behind;
          at 4096, 60 of ~800k, and Tailscale into it went from ~65 to
          ~85 MB/s (2026-10-23).
        '';
      };
      vhostNet = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Move the guest's packets in the host kernel (vhost-net) instead of
          crosvm's jailed device process: a packet per syscall there capped
          small-packet traffic (the tailnet). Off keeps the guest's network
          entirely out of the host kernel's virtio code, at that cost.
        '';
      };
      disks = lib.mkOption { type = lib.types.listOf disk; };
      stopTimeout = lib.mkOption {
        type = lib.types.ints.positive;
        # A node VM with drainOnPowerKey (k3s/shutdown.nix) takes up to 6 min
        # to leave service before its ~2 min shutdown.
        default = 540;
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
        $ip link add link ${v.parentInterface} name ${tap name} address ${v.mac} \
          txqueuelen ${toString v.tapQueueLength} type macvtap mode bridge
        $ip link set ${tap name} netns ${ns name}
        $ip -n ${ns name} link set ${tap name} up
        idx=$($ip -n ${ns name} -o link show ${tap name} | cut -d: -f1)
        dev=/dev/tap$idx
        for _ in $(seq 1 50); do [ -c "$dev" ] && break; sleep 0.1; done
        # Before the chown: root (no CAP_FOWNER here) may chmod only its own.
        chmod 0600 "$dev"
        chown ${vmUser name}: "$dev"
        printf '%s\n' "$dev" > ${netDir name}/tap
        chown ${vmUser name}: ${netDir name}/tap
        for d in ${lib.escapeShellArgs devices}; do
          chown ${vmUser name}: "$(${pkgs.coreutils}/bin/readlink -f "$d")"
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
          --cpus num-cores=${toString v.vcpus}${lib.optionalString (v.pinCpus != null) "\n          --cpu-affinity ${lib.concatStringsSep ":" (lib.imap0 (i: c: "${toString i}=${toString c}") v.pinCpus)}"}
          --no-usb${
            {
              vm = "\n          --per-vm-core-scheduling";
              vcpu = "";
              off = "\n          --core-scheduling false";
            }.${v.coreScheduling}
          }
          --hugepages
          --serial type=stdout,hardware=serial,console=true
          -s ${rt name}/crosvm.sock
          --shared-dir "${core.storeShare}"
          ${lib.concatMapStringsSep "\n      " (
            d: ''--block "path=${d.device},id=${d.serial},o_direct=true"''
          ) v.disks}
          --net tap-fd=3,mac=${v.mac},mrg-rxbuf=true${lib.optionalString v.vhostNet ",vhost-net"}
        )
        for p in ${lib.escapeShellArgs params}; do args+=(-p "$p"); done
        exec ${pkgs.crosvm}/bin/crosvm --extended-status "''${args[@]}" \
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
          # Any exit but a power-off's 0 (--extended-status, above), except
          # crosvm's own "invalid argument", which a retry won't fix.
          Restart = "on-failure";
          RestartPreventExitStatus = 35;
          RestartSec = 10;

          User = vmUser name;
          Group = vmUser name;
          SystemCallFilter = core.hardening.jailedSyscallFilter;
          RuntimeDirectory = "node-vm/${name}";
          RuntimeDirectoryMode = "0700";
          ReadWritePaths = [ (rt name) ];
          PrivatePIDs = true;
          # Every macvtap node, not just this VM's: its /dev/tap<ifindex> is
          # new at each start (prep), and DeviceAllow takes a fixed path. The
          # node's owner and mode (prep: this VM's uid, 0600) keep the other
          # VMs' VMMs out of it.
          DeviceAllow = [
            "/dev/kvm rw"
            "char-macvtap rw"
          ]
          # root:kvm 0666 (udev's static node); the VMM is in kvm anyway.
          ++ lib.optional v.vhostNet "/dev/vhost-net rw"
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
      }) cfg
      ++ lib.mapAttrsToList (name: v: {
        assertion = v.pinCpus == null || builtins.length v.pinCpus == v.vcpus;
        message = "modules.system.nodeVms.${name}: pinCpus needs exactly one host CPU per vCPU (${toString v.vcpus}).";
      }) cfg;

      # CPU steal: a node VM's vCPUs halt and get woken ~15-20k times a second
      # (IPIs, mostly TLB shootdowns), and each wake-up was a VM exit plus a
      # host reschedule: 70-250 us apiece, up to 5-7 of 12 vCPUs stolen at
      # peak (2026-10-24). AVIC delivers interrupts to vCPUs in hardware
      # (needs xAPIC mode in the guest on Zen 3: nox2apic, below), and a
      # longer KVM halt poll (default 200 us) catches most wake-ups before the
      # vCPU thread sleeps: 69 -> 40 us per wake-up, guest steal 10.9 -> 5.0%.
      boot.kernelParams = [
        "kvm_amd.avic=1"
        "kvm.halt_poll_ns=500000"
      ]
      # The pinned vCPUs' CPUs belong to them alone: no other tasks
      # (isolcpus=domain), no managed IRQs, no periodic tick while one task
      # runs (nohz_full) and no RCU callbacks (rcu_nocbs).
      ++ lib.optionals (pinned != [ ]) (
        let l = lib.concatMapStringsSep "," toString pinned; in
        [ "isolcpus=domain,managed_irq,${l}" "nohz_full=${l}" "rcu_nocbs=${l}" ]
      );

      boot.kernelModules = [
        "macvtap"
      ]
      ++ lib.optional (lib.any (v: v.vhostNet) (lib.attrValues cfg)) "vhost_net";

      # Huge pages for guest memory (crosvm --hugepages), which is a memfd:
      # shmem, whose THP is off by default. advise: only where asked.
      systemd.tmpfiles.rules = [
        "w /sys/kernel/mm/transparent_hugepage/shmem_enabled - - - - advise"
      ];

      users.users = lib.mapAttrs' (
        name: _:
        lib.nameValuePair (vmUser name) {
          isSystemUser = true;
          group = vmUser name;
          description = "node VM ${name} (crosvm)";
        }
      ) cfg;
      users.groups = lib.mapAttrs' (name: _: lib.nameValuePair (vmUser name) { }) cfg;

      # Transitional (the switch from one shared uid, node-vm, to a uid per
      # VM; drop once every VM has restarted under its own). A rebuild
      # doesn't restart a running VM, so one started before it still runs as
      # the old uid, in a runtime dir and with a control socket of that
      # uid's, 0700, while its unit's ExecStop now runs as the new uid: the
      # power button wouldn't reach it, and a stop (`node-vm restart`, the
      # machine's shutdown) would be TimeoutStopSec and SIGKILL instead of
      # the guest's own shutdown. So the new uid gets in, by ACL: through
      # the dir, and to the socket. Done as the dir's owner, not root: what
      # the old VMM might have put in its place is only ever its own.
      system.activationScripts.node-vm-own-uid = {
        deps = [ "users" ];
        text = lib.concatMapStrings (
          name:
          let
            d = rt name;
          in
          ''
            if [ -d ${d} ] && [ ! -L ${d} ]; then
              old=$(${pkgs.coreutils}/bin/stat -c %u ${d})
              new=$(${pkgs.coreutils}/bin/id -u ${vmUser name} 2>/dev/null || echo)
              if [ -n "$new" ] && [ "$old" != "$new" ] && [ "$old" != 0 ]; then
                ${pkgs.util-linux}/bin/setpriv --reuid="$old" \
                  --regid="$(${pkgs.coreutils}/bin/stat -c %g ${d})" --clear-groups --no-new-privs \
                  ${pkgs.acl}/bin/setfacl -m u:"$new":x ${d} || true
                ${pkgs.util-linux}/bin/setpriv --reuid="$old" \
                  --regid="$(${pkgs.coreutils}/bin/stat -c %g ${d})" --clear-groups --no-new-privs \
                  ${pkgs.acl}/bin/setfacl -m u:"$new":rw ${d}/crosvm.sock || true
              fi
            fi
          ''
        ) (lib.attrNames cfg);
      };

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
      boot.kernelParams = [
        "console=ttyS0,115200"
        # A panic restarts the VM (crosvm exits, the unit restarts).
        "panic=-1"
        # xAPIC, not x2APIC: Zen 3 has AVIC but not x2AVIC, and KVM turns
        # AVIC off for a guest in x2APIC mode (see the host side above).
        "nox2apic"
      ];
      # Poll briefly before halting an idle vCPU, so a wake-up that comes
      # quickly needs no VM exit. crosvm doesn't advertise KVM's
      # poll-control feature, hence force. Measured: IPIs roughly halved.
      boot.kernelModules = [ "cpuidle-haltpoll" ];
      boot.extraModprobeConfig = "options cpuidle_haltpoll force=1";
      # No nix here: the store is the machine's and read-only (and its GC is
      # the machine's, which keeps this system: the machine's config holds it).
      nix.enable = false;
      nix.gc.automatic = lib.mkForce false;
      nix.optimise.automatic = lib.mkForce false;
      # No firmware to update in a VM; its refresh timer only loaded modules at random.
      services.fwupd.enable = lib.mkForce false;
    })

    # CPU is what these VMs are short of: no zeroing of every page on
    # allocation and free (hardening.nix, zeroMemory). Where the option
    # exists: the smoke guest has no hardening module.
    (lib.optionalAttrs (lib.hasAttrByPath [ "modules" "system" "hardening" "zeroMemory" ] options) (
      lib.mkIf guestCfg.enable { modules.system.hardening.zeroMemory = false; }
    ))

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
