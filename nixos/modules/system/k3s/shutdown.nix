# Taking a node VM down without its users noticing.
#
# A node VM goes down by its power button: the machine's node-vm unit
# presses it (crosvm powerbtn) when the VM is restarted or the machine shuts
# down. Left to logind, that starts kubelet's graceful shutdown at once: the
# node's pods are killed while they're still in their Services' endpoints and
# the node still hosts svc:k8s, so for about a minute some requests, in the
# cluster and from outside, go to pods that are gone (carrack, 2026-10-25:
# every public site down 60-120 s; LDAP, Redis and DNS lookups failing in the
# cluster). svc:k8s was drained only when tailscale-serve stopped, after the
# pods, a second before tailscaled itself.
#
# With drainOnPowerKey the button runs node-power-off instead, which takes the
# node out of service first and then powers off:
#  1. svc:k8s drained: no new connections from the tailnet (the VPS
#     ingresses), open ones finish; Tailscale sends new ones to the others.
#  2. cordoned (and uncordoned at the next boot, by node-shutdown-finish,
#     unless someone else had cordoned it).
#  3. lcm pods live-migrated off (lcm drain): mc-no-evict forbids evicting
#     them, and a migration keeps their players.
#  4. the rest drained: evictions take pods out of their endpoints before
#     they stop, single-replica ones start on another node meanwhile, and a
#     CNPG primary is switched over. Ceph's mons, OSDs and mgr stay for
#     kubelet's shutdown, which stops them last (see gracePeriod).
# Each step is bounded, and the unit powers off however it ends
# (SuccessAction/FailureAction), so a stuck drain can only delay the power-off
# (by up to TimeoutStartSec), never stop it. The machine waits stopTimeout
# (node-vm.nix) for the VM.
#
# node-rollout's reboots drain the node themselves; they now leave svc:k8s
# first too (rollout.nix).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.system.k3s;
  enable = cfg.enable && config.modules.system.nodeVmGuest.enable && cfg.drainOnPowerKey;
  host = config.networking.hostName;
  state = "/persist/node-shutdown";
  lcm = config.services.lcm;
  tls = lcm.transportTLS or { };
  env = {
    KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
  }
  // lib.optionalAttrs (lcm.enable && (tls.enable or false) && (tls.transferNetwork or null) != null) {
    LCM_TRANSFER_NETWORK = tls.transferNetwork;
  };
  inputs = [
    config.services.k3s.package
    pkgs.coreutils
  ]
  ++ lib.optional lcm.enable lcm.package;

  prepare = pkgs.writeShellApplication {
    name = "node-prepare-shutdown";
    runtimeInputs = inputs;
    text = ''
      node=${host}
      k() { k3s kubectl "$@"; }
      log() { printf 'node-prepare-shutdown: %s\n' "$*" >&2; }

      ${lib.optionalString cfg.tailscaleServices ''
        log "leaving svc:k8s: open connections finish, new ones go to the other nodes"
        ${lib.getExe config.services.tailscale.package} serve drain svc:k8s || log "tailscale serve drain failed"
      ''}
      mkdir -p ${state}
      if [ "$(k get node "$node" -o jsonpath='{.spec.unschedulable}' 2>/dev/null)" != true ]; then
        if k cordon "$node"; then touch ${state}/cordoned; else log "cordon failed"; fi
      fi
      ${lib.optionalString lcm.enable ''
        log "live-migrating lcm pods off"
        timeout 200 lcm drain "$node" || log "lcm drain didn't finish: what's left stops with the node"
      ''}
      log "draining the rest (Ceph's mons, OSDs and mgr stay for kubelet's shutdown)"
      k drain "$node" --ignore-daemonsets --delete-emptydir-data \
        --pod-selector='app notin (rook-ceph-osd,rook-ceph-mon,rook-ceph-mgr)' --timeout=120s \
        || log "the drain didn't finish in 120 s: kubelet stops the rest"
    '';
  };

  finish = pkgs.writeShellApplication {
    name = "node-shutdown-finish";
    runtimeInputs = inputs;
    text = ''
      node=${host}
      k() { k3s kubectl "$@"; }
      for _ in $(seq 360); do
        [ "$(k get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] \
          && k -n kube-system wait --for=condition=Ready pod -l k8s-app=cilium \
            --field-selector "spec.nodeName=$node" --timeout=10s >/dev/null 2>&1 \
          && break
        sleep 5
      done
      # A node-rollout reboot cordoned it too: node-rollout-finish uncordons.
      [ -e /persist/node-rollout/pending ] || k uncordon "$node"
      rm -f ${state}/cordoned
    '';
  };
in
{
  options.modules.system.k3s.drainOnPowerKey = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      On the power button (how the machine stops a node VM), take the node out
      of service (svc:k8s drained, cordoned, lcm pods migrated, pods drained),
      then power off; uncordon at the next boot. See shutdown.nix.
    '';
  };

  config = lib.mkIf enable {
    # The button is node-power-off's, not logind's (acpid gets the ACPI event).
    services.logind.settings.Login.HandlePowerKey = "ignore";
    services.acpid = {
      enable = true;
      powerEventCommands = "${pkgs.systemd}/bin/systemctl start --no-block node-power-off.service";
    };

    systemd.services.node-power-off = {
      description = "Take the node out of service, then power off (the power button)";
      environment = env;
      unitConfig = {
        SuccessAction = "poweroff";
        FailureAction = "poweroff";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe prepare;
        TimeoutStartSec = 360;
      };
    };

    systemd.services.node-shutdown-finish = {
      description = "Uncordon the node after a power-button shutdown";
      wantedBy = [ "multi-user.target" ];
      after = [ "k3s.service" ];
      wants = [ "k3s.service" ];
      environment = env;
      unitConfig.ConditionPathExists = "${state}/cordoned";
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe finish;
        TimeoutStartSec = "40min";
      };
    };

    environment.systemPackages = [ prepare ];
  };
}
