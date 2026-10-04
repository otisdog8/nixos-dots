# The agent VM: one long-running crosvm VM per host, where orchestrated,
# headless coding agents (claude, codex) work, each project as its own user.
# agent-auth's sandboxd runs inside it (modules.agentVm.guestModules), and
# agent-auth's hostd on the host can freeze or stop it (the kill switch).
# Design: agent-auth's docs/sandbox-design.md.
#
# Deliberately separate from the app sandbox tier (sandbox-vm.nix,
# lib/vm/instance.nix): it is an always-on system service with no desktop
# session behind it (headless hosts run it too), its own guest system
# (lib/vm/agent-guest.nix: persistent disk, writable store, many users), and
# its own uids. It shares the VM building blocks in lib/vm/core: passt and its
# unit, the VMM's sandbox, the shared-dir flags, the CID allocation.
#
# Host side:
#   agent-vm.service       the VMM, as sbx-agentvm (group kvm); its disk (an
#                          image bound in from /large, or a dedicated block
#                          device) is all it sees of the host's data
#   agent-vm-prep.service  root: per-boot runtime dir and SSH keys, the disk
#                          image (created sparse and nodatacow on first start)
#   agent-vm-net.service   passt, as sbx-agentvm-net: the network policy below
#                          (cgroup IP filter + owner-matched port limits)
# Operators (members of agent-vm-users) get `agent-vm ssh|status|log|restart`.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.agentVm;
  core = import ../../../lib/vm/core { inherit lib pkgs; };
  netpolicy = import ../../../lib/netpolicy.nix { inherit lib; };

  unit = "agent-vm";
  rt = "/run/agent-vm";
  cid = core.cid.agentVm;
  vmUser = "sbx-agentvm";
  netUser = "sbx-agentvm-net";
  group = "sbx-agentvm";
  operators = "agent-vm-users";
  diskTarget = "${rt}/disk.img";
  blockDisk = cfg.disk.type == "block";
  # What crosvm opens: the image's bind mount point, or the device itself.
  diskArg = if blockDisk then cfg.disk.path else diskTarget;

  guest = inputs.nixpkgs.lib.nixosSystem {
    specialArgs.agentVmHost = {
      inherit (cfg) substituters trustedPublicKeys;
      hostName = config.networking.hostName;
      locale = config.i18n.defaultLocale;
      timeZone = config.time.timeZone;
      stateVersion = config.system.stateVersion;
      # Same kernel as the host: nothing extra to build, and it has virtio-fs/vsock.
      kernelPackages = config.boot.kernelPackages;
    };
    modules = [
      ../../../lib/vm/agent-guest.nix
      # Reuse the host's package set (overlays included).
      { nixpkgs.pkgs = pkgs; }
    ]
    ++ cfg.guestModules;
  };
  guestTop = guest.config.system.build.toplevel;
  # The guest registers its own closure in its store database at boot.
  registration = pkgs.closureInfo { rootPaths = [ guestTop ]; };

  # Addresses with port limits are allowed by address here, then narrowed by
  # the firewall (core.net.portFilter).
  portAddrs = map (r: r.addr) cfg.network.allowPorts;
  dnsNames = cfg.network.allowNames != [ ] && config.services.resolved.enable;
  netPolicy = netpolicy.lower {
    policy = {
      mode = "internet";
      allow = cfg.network.allow ++ portAddrs;
      deny = [ ];
      allowDns = true;
      inherit (cfg.network) allowNames;
    };
    backendDefault = "internet";
    dns = if dnsNames then [ "127.0.0.53" ] else cfg.dns;
  };
  portFilter = core.net.portFilter {
    chain = "agent-vm-egress";
    uid = netUser;
    rules = cfg.network.allowPorts;
  };

  co = "${pkgs.coreutils}/bin";
  crosvm = "${pkgs.crosvm}/bin/crosvm";

  prepScript = pkgs.writeShellScript "${unit}-prep" ''
    set -euo pipefail
    umask 077
    ${co}/rm -rf -- ${rt}
    ${co}/install -d -m 0711 ${rt}
    ${co}/install -d -m 0700 -o ${vmUser} -g ${group} ${rt}/meta ${rt}/ctl
    # passt (sbx-agentvm-net) makes the socket; the VMM connects as the group.
    ${co}/install -d -m 0750 -o ${netUser} -g ${group} ${rt}/net
    ${co}/install -d -m 0750 -g ${operators} ${rt}/client
    ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "${unit}" -f ${rt}/meta/ssh_host_ed25519_key
    ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "operators@${unit}" -f ${rt}/client/id_ed25519
    ${co}/install -m 0644 ${rt}/client/id_ed25519.pub ${rt}/meta/authorized_keys
    printf '${unit} %s\n' "$(${co}/cut -d' ' -f1,2 ${rt}/meta/ssh_host_ed25519_key.pub)" > ${rt}/client/known_hosts
    ${co}/chown ${vmUser}:${group} ${rt}/meta/*
    ${co}/chown root:${operators} ${rt}/client/*
    ${co}/chmod 0640 ${rt}/client/*

    ${if blockDisk then blockPrep else imagePrep}
  '';
  disk = lib.escapeShellArg cfg.disk.path;
  # The image: sparse, created once, always owned by the VMM's uid (which may
  # differ across rebuilds on a host that doesn't persist its uid map). On a
  # copy-on-write host filesystem (btrfs) it is nodatacow: random writes into a
  # CoW file fragment it badly. +C only takes on files created empty, hence on
  # the directory before the image exists; elsewhere chattr fails harmlessly.
  # Compression and checksums come from the guest's own btrfs instead.
  imagePrep = ''
    ${co}/install -d -m 0700 -o ${vmUser} -g ${group} ${lib.escapeShellArg (dirOf cfg.disk.path)}
    if [ ! -e ${disk} ]; then
      ${pkgs.e2fsprogs}/bin/chattr +C ${lib.escapeShellArg (dirOf cfg.disk.path)} 2>/dev/null || true
      ${co}/truncate -s ${cfg.disk.size} ${disk}
    fi
    ${co}/chown ${vmUser}:${group} ${disk}
    ${co}/chmod 0600 ${disk}
    # Mount point for the unit's private bind of the image.
    ${co}/install -m 0600 -o ${vmUser} -g ${group} /dev/null ${diskTarget}
  '';
  # A dedicated device (an LV, a partition, a zvol): nothing to create; it must
  # exist. The VMM gets it by ownership, re-applied on every start (udev may
  # reset it when the device changes; crosvm opens it once, at start), and by
  # DeviceAllow.
  blockPrep = ''
    dev="$(${co}/readlink -f ${disk})"
    if [ ! -b "$dev" ]; then
      echo "${unit}: ${cfg.disk.path} is not a block device" >&2
      exit 1
    fi
    ${co}/chown ${vmUser}:${group} "$dev"
    ${co}/chmod 0600 "$dev"
  '';

  netScript = core.net.script {
    name = "${unit}-net";
    socket = "${rt}/net/passt.sock";
    forwardToResolved = dnsNames;
    inherit (cfg) dns;
  };

  guestKernelParams = guest.config.boot.kernelParams ++ [
    "init=${guestTop}/init"
    "agentvm.registration=${registration}/registration"
  ];
  runScript = pkgs.writeShellScript "${unit}-run" ''
    set -euo pipefail
    ${core.hardening.vsockNsCheck}
    for _ in $(${co}/seq 1 200); do [ -S ${rt}/net/passt.sock ] && break; ${co}/sleep 0.05; done
    if [ ! -S ${rt}/net/passt.sock ]; then
      echo "${unit}: passt never created its socket; see the journal of ${unit}-net" >&2
      exit 1
    fi
    args=(
      run
      --name sbx-${unit}
      --mem size=${toString cfg.memory}
      --cpus num-cores=${toString cfg.vcpus}
      --no-usb
      --balloon-page-reporting
      --serial type=stdout,hardware=serial,console=true
      --vsock "cid=${toString cid}"
      -s ${rt}/ctl/crosvm.sock
      --shared-dir "${core.storeShare}"
      --shared-dir "${rt}/meta:sbx-meta:${core.fsCommon}:cache=never"
      --block "path=${diskArg}"
      --vhost-user "type=net,socket=${rt}/net/passt.sock"
    )
    for p in ${lib.escapeShellArgs guestKernelParams}; do args+=(-p "$p"); done
    exec ${crosvm} "''${args[@]}" \
      --initrd ${guest.config.system.build.initialRamdisk}/${guest.config.system.boot.loader.initrdFile} \
      ${guest.config.boot.kernelPackages.kernel}/${guest.config.system.boot.loader.kernelFile}
  '';

  # ACPI power button → orderly guest shutdown (/persist flushed); systemd kills
  # whatever remains after TimeoutStopSec.
  stopScript = pkgs.writeShellScript "${unit}-stop" ''
    exec ${crosvm} powerbtn ${rt}/ctl/crosvm.sock
  '';

  # Operators' entry point. The client key is readable by agent-vm-users only:
  # membership is root in the agent VM.
  cli = pkgs.writeShellScriptBin "agent-vm" ''
    set -euo pipefail
    ssh_vm() {
      exec ${pkgs.openssh}/bin/ssh \
        -i ${rt}/client/id_ed25519 \
        -o IdentitiesOnly=yes \
        -o UserKnownHostsFile=${rt}/client/known_hosts \
        -o HostKeyAlias=${unit} \
        -o StrictHostKeyChecking=yes \
        -o "ProxyCommand=${pkgs.systemd}/lib/systemd/systemd-ssh-proxy %h %p" \
        "$@" root@vsock/${toString cid}
    }
    case "''${1:-}" in
      ssh) shift; ssh_vm -t "$@" ;;
      status) exec ${pkgs.systemd}/bin/systemctl status --no-pager ${unit} ${unit}-net ;;
      log) shift; exec ${pkgs.systemd}/bin/journalctl -u ${unit} "$@" ;;
      start|stop|restart) exec ${pkgs.systemd}/bin/systemctl "$1" ${unit} ;;
      *) echo "usage: agent-vm ssh [CMD…] | status | log [-f] | start | stop | restart" >&2; exit 2 ;;
    esac
  '';
in
{
  options.modules.agentVm = {
    enable = lib.mkEnableOption "the agent VM (headless coding agents, see agent-auth)";

    memory = lib.mkOption {
      type = lib.types.ints.positive;
      default = 16384;
      description = "Guest RAM in MiB. Committed as the guest touches it; free pages are reported back.";
    };
    vcpus = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8;
    };

    disk = {
      type = lib.mkOption {
        type = lib.types.enum [
          "file"
          "block"
        ];
        default = "file";
        description = ''
          "file": a sparse image on the host's filesystem (created on first
          start). "block": a dedicated block device — an LVM (thin) LV, a
          partition or a zvol — with no host filesystem in between; better
          where one is available.
        '';
      };
      path = lib.mkOption {
        type = lib.types.str;
        default = "/large/agent-vm/disk.img";
        example = "/dev/vg0/agent-vm";
        description = ''
          The guest's data disk (/persist in the guest: projects, homes, the
          store's writable layer, the store database, logs). For a file, the
          image path (/large is persisted but not backed up). For a block
          device, a stable path (/dev/<vg>/<lv>, /dev/disk/by-id/…), never
          /dev/dm-N.
        '';
      };
      size = lib.mkOption {
        type = lib.types.str;
        default = "256G";
        description = "Size the image is created with (file only; sparse, so only written blocks take space). Not applied to an existing image.";
      };
    };

    dns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = config.modules.sandbox.vm.dns;
      defaultText = lib.literalExpression "config.modules.sandbox.vm.dns";
      description = "Resolvers the guest uses when network.allowNames is empty (otherwise its DNS goes through the host's resolved).";
    };

    network = {
      allow = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Addresses/CIDRs reachable on every port, on top of the internet. The
          guest otherwise reaches no host, LAN or tailnet address (netpolicy
          "internet").
        '';
      };
      allowNames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "gateway.example.org" ];
        description = "Names whose addresses are opened as they resolve (sbx-dnsallow).";
      };
      allowPorts = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              addr = lib.mkOption { type = lib.types.str; };
              ports = lib.mkOption { type = lib.types.listOf lib.types.port; };
            };
          }
        );
        default = [ ];
        example = [
          {
            addr = "100.64.0.10";
            ports = [ 443 ];
          }
        ];
        description = "IPv4 addresses reachable on these TCP ports only (iptables, matched on passt's uid).";
      };
    };

    substituters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "https://cache.nixos.org" ];
      description = "Binary caches for the guest's nix-daemon (must be reachable under the network policy).";
    };
    trustedPublicKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" ];
    };

    guestModules = lib.mkOption {
      type = lib.types.listOf lib.types.deferredModule;
      default = [ ];
      description = "Extra NixOS modules for the guest (agent-auth's sandboxd goes here).";
    };

    operators = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ config.modules.sandbox.vm.user ];
      defaultText = lib.literalExpression "[ config.modules.sandbox.vm.user ]";
      description = "Host users who may use `agent-vm` (SSH in as the guest's root, start/stop the VM).";
    };

    guest = lib.mkOption {
      type = lib.types.unspecified;
      readOnly = true;
      internal = true;
      description = "The evaluated guest system.";
    };
  };

  config = lib.mkIf cfg.enable {
    modules.agentVm.guest = guest;

    assertions = [
      {
        assertion = lib.all (r: builtins.match "[0-9.]+" r.addr != null) cfg.network.allowPorts;
        message = "modules.agentVm.network.allowPorts: IPv4 addresses only (the port filter is iptables).";
      }
      {
        assertion = cfg.network.allowNames == [ ] || config.services.resolved.enable;
        message = "modules.agentVm.network.allowNames needs systemd-resolved on the host.";
      }
    ];

    users.groups.${group} = { };
    users.groups.${operators}.members = cfg.operators;
    users.users.${vmUser} = {
      isSystemUser = true;
      inherit group;
      description = "agent VM (crosvm)";
    };
    users.users.${netUser} = {
      isSystemUser = true;
      inherit group;
      description = "agent VM network (passt)";
    };

    environment.systemPackages = [ cli ];

    networking.firewall.extraCommands = portFilter.start;
    networking.firewall.extraStopCommands = portFilter.stop;

    modules.sandbox.dnsAllow = lib.optional (netPolicy.names != [ ]) {
      units = [ "${unit}-net.service" ];
      inherit (netPolicy) names;
    };

    # Operators may start, stop and restart the VM (not reconfigure it).
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            subject.isInGroup("${operators}") &&
            action.lookup("unit") == "${unit}.service") {
          var verb = action.lookup("verb");
          if (verb == "start" || verb == "stop" || verb == "restart") {
            return polkit.Result.YES;
          }
        }
      });
    '';

    systemd.services = {
      ${unit} = {
        description = "Agent VM";
        wantedBy = [ "multi-user.target" ];
        requires = [
          "${unit}-prep.service"
          "${unit}-net.service"
        ];
        after = [
          "${unit}-prep.service"
          "${unit}-net.service"
          "network-online.target"
        ];
        wants = [ "network-online.target" ];
        # A rebuild never kills running agents; a changed guest takes effect on
        # the next VM restart (`agent-vm restart`).
        restartIfChanged = false;
        stopIfChanged = false;
        serviceConfig = {
          Type = "simple";
          ExecStart = runScript;
          ExecStop = "-${stopScript}";
          TimeoutStopSec = 60;
          KillMode = "mixed";
          Restart = "on-failure";
          RestartSec = 10;

          User = vmUser;
          Group = group;
          SystemCallFilter = core.hardening.jailedSyscallFilter;
          # Nothing of the host's data is visible: the disk image is bound to
          # a mount point in the runtime dir.
          InaccessiblePaths = [
            "-/persist"
            "-/large"
            "-/cache"
          ];
          BindPaths = lib.optional (!blockDisk) ''"${cfg.disk.path}":"${diskTarget}"'';
          ReadWritePaths = [ rt ];
          DeviceAllow = [
            "/dev/kvm rw"
            "/dev/vhost-vsock rw"
          ]
          ++ lib.optional blockDisk "${cfg.disk.path} rw";
          MemoryMax = "${toString (cfg.memory + 512)}M";
        }
        // core.hardening.vmm;
      };

      "${unit}-prep" = {
        description = "Agent VM keys, runtime dir and disk";
        bindsTo = [ "${unit}.service" ];
        restartIfChanged = false;
        stopIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = prepScript;
          ExecStop = "${co}/rm -rf -- ${rt}";
          PrivateNetwork = true;
          ProtectHome = true;
        };
      };

      "${unit}-net" = {
        description = "Agent VM network (passt)";
        bindsTo = [ "${unit}.service" ];
        requires = [ "${unit}-prep.service" ];
        after = [ "${unit}-prep.service" ];
        restartIfChanged = false;
        stopIfChanged = false;
        serviceConfig =
          core.net.serviceConfig {
            user = netUser;
            inherit group;
            policy = netPolicy;
            readWritePaths = [ rt ];
          }
          // {
            ExecStart = netScript;
            # The socket must be connectable by the VMM (same group).
            UMask = "0007";
          };
      };
    };
  };
}
