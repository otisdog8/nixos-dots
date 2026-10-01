# VM sandbox tier: host-wide pieces shared by every app's microVM.
#
# The per-app parts (units, launcher, spec) come from lib/backends/vm.nix, which
# every mkApp app evaluates alongside its container backend; this module owns the
# single generic guest system they all boot (lib/vm/guest.nix), the graphics
# stack they share, and the runtime directory their units work in. The guest is
# only evaluated/built when some app actually uses its VM variant (mode = "vm" or
# modules.sandbox.variants.enable).
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.modules.sandbox.vm;
  user = config.users.users.${cfg.user};
  hasNvidia = lib.elem "nvidia" config.services.xserver.videoDrivers;

  nvgpu = import ../../../lib/vm/nvgpu.nix {
    inherit lib pkgs;
    src = inputs.virtio-nvgpu;
  };

  # Groups (modules.sandbox.groups) as VMs: one instance per group, from the
  # member records of whichever of its apps are enabled here.
  mkInstance = import ../../../lib/vm/instance.nix { inherit config lib pkgs; };
  groupMembers = g: map (a: cfg.members.${a}) (lib.filter (a: cfg.members ? ${a}) g.apps);
  groupsWithMembers = lib.filterAttrs (_: g: groupMembers g != [ ]) config.modules.sandbox.groups;
  mkGroupInstance =
    name: g:
    mkInstance {
      name = "group-${name}";
      label = "${name} sandbox";
      members = groupMembers g;
      inherit (g) persistent projects;
      # Launching a member from an undeclared folder in ~ grants it to the VM.
      grantCwd = true;
      extraBinds = map (p: {
        path = p;
        ro = false;
      }) g.shareHome;
      inherit (g) network;
      inherit (g.vm)
        memory
        vcpus
        gpuMemoryMiB
        gpuMemoryProcessPercent
        tuning
        ;
    };

  # `sandbox-vm list | stop NAME [PROJECT-DIR] | status NAME [PROJECT-DIR]`:
  # manage running sandbox VMs (units the user may start/stop via polkit).
  sandboxVmCli = pkgs.writeShellScriptBin "sandbox-vm" ''
    set -euo pipefail
    unit_for() {
      if [ -n "''${2:-}" ]; then
        printf 'sandbox-vm-%s@%s.service' "$1" "$(${pkgs.systemd}/bin/systemd-escape --path -- "$(${pkgs.coreutils}/bin/realpath -- "$2")")"
      else
        printf 'sandbox-vm-%s.service' "$1"
      fi
    }
    case "''${1:-list}" in
      list)
        ${pkgs.systemd}/bin/systemctl list-units --no-legend --plain --state=active 'sandbox-vm-*.service' \
          | ${pkgs.gnugrep}/bin/grep -Ev -- '-(prep|net|wl|gpu|relay|bus|capture-bus|capture-broker|grantsfs|grants|docs|camera)(@.*)?\.service' \
          | ${pkgs.gawk}/bin/awk '{print $1}' | ${pkgs.gnused}/bin/sed -E 's/^sandbox-vm-//; s/\.service$//' || true ;;
      stop) ${pkgs.systemd}/bin/systemctl stop "$(unit_for "$2" "''${3:-}")" ;;
      camera)
        # sandbox-vm camera NAME [attach|detach] [PROJECT-DIR]: you asking is the approval.
        u="$(unit_for "$2" "''${4:-}")"
        cu="''${u%%@*}"; cu="''${cu%.service}-camera"
        case "$u" in *@*) cu="$cu@''${u#*@}" ;; *) cu="$cu.service" ;; esac
        case "''${3:-attach}" in
          attach) ${pkgs.systemd}/bin/systemctl start "$cu" ;;
          detach) ${pkgs.systemd}/bin/systemctl stop "$cu" ;;
          *) echo "usage: sandbox-vm camera NAME [attach|detach] [PROJECT-DIR]" >&2; exit 2 ;;
        esac ;;
      status) ${pkgs.systemd}/bin/systemctl status --no-pager "$(unit_for "$2" "''${3:-}")" ;;
      *) echo "usage: sandbox-vm list | stop NAME [PROJECT-DIR] | status NAME [PROJECT-DIR] | camera NAME [attach|detach] [PROJECT-DIR]" >&2; exit 2 ;;
    esac
  '';

  guest = inputs.nixpkgs.lib.nixosSystem {
    specialArgs.sbxHost = {
      dbusProxy = cfg.dbusProxy;
      inherit (cfg) user graphics;
      inherit (user) uid group;
      gid = config.users.groups.${user.group}.gid;
      locale = config.i18n.defaultLocale;
      timeZone = config.time.timeZone;
      stateVersion = config.system.stateVersion;
      # Same kernel as the host: nothing extra to build, and it has virtio-fs/vsock.
      kernelPackages = config.boot.kernelPackages;
      # virtio-nvgpu guests run NVIDIA's userspace at exactly the host driver's
      # release, so they take the host's own driver package.
      nvidiaPackage = if cfg.nvgpuAvailable then config.hardware.nvidia.package else null;
      # null: no VM on this host gets virtio-nvgpu, so the guest carries none of it.
      nvgpu =
        if cfg.nvgpuAvailable then
          {
            inherit (nvgpu) wlGuest;
            kmod = nvgpu.kmod config.boot.kernelPackages;
          }
        else
          null;
    };
    modules = [
      ../../../lib/vm/guest.nix
      # Reuse the host's package set (overlays included) instead of instantiating
      # nixpkgs a second time.
      { nixpkgs.pkgs = pkgs; }
    ]
    ++ cfg.guestModules;
  };
in
{
  options.modules.sandbox.vm = {
    user = lib.mkOption {
      type = lib.types.str;
      default = "jrt";
      description = "The host user whose session launches VM-sandboxed apps; mirrored (same name/uid) inside the guest.";
    };

    nested = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Default for modules.apps.<app>.sandbox.vm.nested: inside the VM, run the
        app in its nixpak (bwrap) sandbox too, so a compromised app is still
        confined within the guest (its other members, the broker and grant
        sockets, the rest of the guest filesystem). Defense in depth; off by
        default until it has been tried on hardware.
      '';
    };

    dns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "9.9.9.9"
        "149.112.112.112"
      ];
      description = ''
        Resolvers handed to VM guests (via passt's DHCP). Public ones: the host's
        own resolver listens on loopback, which the guest network can't reach.
      '';
    };

    graphics = lib.mkOption {
      type = lib.types.enum [
        "auto"
        "nvgpu"
        "cross-domain"
        "none"
      ];
      default = "auto";
      description = ''
        How apps in VMs reach the display and the GPU. Two mechanisms:
        - virtio-nvgpu (lib/vm/nvgpu.nix): the guest runs NVIDIA's own driver
          against the host GPU, and its Wayland clients are clients of the host
          compositor with zero-copy GPU buffers. Apps with the gpu capability also
          get compute (CUDA). NVIDIA hosts only.
        - cross-domain: crosvm's virtio-gpu cross-domain Wayland; the guest
          renders in software, and no host GPU is reachable at all. Any host.
        Modes:
        - auto: virtio-nvgpu for VMs with an app that has the gpu capability (on
          NVIDIA hosts), cross-domain for every other GUI app.
        - nvgpu: virtio-nvgpu for every GUI app too.
        - cross-domain: cross-domain for every GUI app; no VM gets the GPU.
        - none: no display; GUI apps start but show nothing.
        Either way the guest's windows reach Hyprland through a
        wp_security_context_v1 socket, like the container backends.
      '';
    };

    nvgpuAvailable = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      internal = true;
      default =
        hasNvidia
        && lib.elem cfg.graphics [
          "auto"
          "nvgpu"
        ];
      description = "Whether any VM may get virtio-nvgpu on this host.";
    };

    prefaultMemory = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        virtio-nvgpu VMs: fault all guest RAM in and collapse it onto 2 MiB pages
        at boot (crosvm --prefault-memory, the fork's patch 0011), instead of on
        first touch one 4 KiB page at a time, which stalls frames for 20-40 ms.
        Each such VM then holds all of its memory from boot (and free-page
        reporting is off for it). Other VMs are unaffected.
      '';
    };

    dbusProxy = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      default = import inputs.vm-dbus-proxy { inherit pkgs; };
      description = "D-Bus and consented screen-capture adapters for sandbox VMs.";
    };

    nvgpu = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      internal = true;
      default = nvgpu;
      description = "virtio-nvgpu's packages (lib/vm/nvgpu.nix).";
    };

    guestModules = lib.mkOption {
      type = lib.types.listOf lib.types.deferredModule;
      default = [ ];
      description = ''
        Extra NixOS modules for the generic guest system. There is ONE guest
        system per host, shared by every VM, so whatever goes here is in every
        guest: keep it inert unless the app that needs it runs (e.g. a
        D-Bus-activated service, a polkit policy). Per-VM behaviour belongs in
        the app's sandbox.vm.guestServices / guestBinds instead.
      '';
    };

    guest = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      internal = true;
      default = guest;
      description = "The evaluated generic guest NixOS system (lib/vm/guest.nix).";
    };

    members = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      default = { };
      internal = true;
      description = "Every VM-capable app's member record (lib/backends/vm.nix), by app name.";
    };

    groupInstances = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      readOnly = true;
      internal = true;
      default = lib.mapAttrs mkGroupInstance groupsWithMembers;
      description = "Each sandbox group's VM instance (lib/vm/instance.nix).";
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.graphics != "nvgpu" || hasNvidia;
        message = "modules.sandbox.vm.graphics = \"nvgpu\" needs the NVIDIA driver on the host (services.xserver.videoDrivers).";
      }
    ]
    ++ lib.concatMap (i: i.assertions) (lib.attrValues cfg.groupInstances);

    # The groups' VMs (their members' own VM units aren't generated).
    systemd.services = lib.mkMerge (map (i: i.services) (lib.attrValues cfg.groupInstances));
    modules.sandbox.units = lib.concatMap (i: i.polkitUnits) (lib.attrValues cfg.groupInstances);
    modules.sandbox.dnsAllow = lib.concatMap (i: i.dnsAllow) (lib.attrValues cfg.groupInstances);
    users.users = lib.mkMerge (map (i: i.gpuUsers.users or { }) (lib.attrValues cfg.groupInstances));
    users.groups = lib.mkMerge (map (i: i.gpuUsers.groups or { }) (lib.attrValues cfg.groupInstances));
    modules.sandbox.broker.sandboxes = lib.mapAttrs' (
      _: i: lib.nameValuePair i.brokerName i.brokerEntry
    ) cfg.groupInstances;

    environment.systemPackages = [ sandboxVmCli ];

    # /run/sandbox-vm/<app>/<id>: per-launch keys, sockets and share mount points,
    # created and removed by each VM's root prep/cleanup (lib/backends/vm.nix).
    # Traversable, never listable or writable by unprivileged users.
    systemd.tmpfiles.rules = [ "d /run/sandbox-vm 0711 root root -" ];
  };
}
