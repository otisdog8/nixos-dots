# Rolling a new system onto a node VM, one node at a time, from inside it.
#
# A node VM boots whatever system its machine pins (node-vm.nix), and the
# machine's rebuild never restarts it. So, after the machine's rebuild:
#
#   node-rollout [--reboot | --bounce] /nix/store/...-nixos-system-<node>-...
#
# Safe (the default):
# - One node at a time: a Lease, kube-system/node-rollout, held from start
#   to finish, a reboot included. The other nodes must be Ready and not
#   cordoned, and Ceph healthy, before it starts.
# - Same kernel, initrd and kernel parameters: a live switch
#   (switch-to-configuration test: nothing is installed for boot, the
#   machine's pin is the boot entry). Changed units restart, k3s included,
#   whose pods keep running meanwhile. Then it waits for the node, Cilium
#   and Ceph.
# - Otherwise (or --reboot): cordon, live-migrate the lcm pods off (one at
#   a time, none started after 15 minutes, none cut short: lcm-drain.nix),
#   drain (eviction honours PDBs: a CNPG primary waits for its switchover;
#   15 minutes, then it gives up and uncordons), hand the router VIP to
#   another node's gateway (its players move with it; no standby: uncordon,
#   no reboot), Ceph noout, and the guest reboots itself: its unit on the
#   machine boots the pinned system. node-rollout-finish completes it at
#   boot: Ready, uncordon, OSDs up, noout off, Ceph healthy, the Lease
#   released.
#
# --bounce: the reboot, now. No health checks, no drain (kubelet's graceful
# shutdown still stops pods in order), the VIP handed off if a standby takes
# it within 15 s; noout if Ceph answers. Still takes the Lease; the finish
# at boot hands it over once the node is Ready and its OSDs are up, without
# waiting for Ceph to be healthy.
#
# `node-rollout status` says where it is; `node-rollout abort` undoes what
# a stuck one left (cordon, noout, the boot marker, the Lease). Across
# machines: `nix run .#rollout` from any checkout. Agents get both as root
# hostd templates, so a human approves each.
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  enable = config.modules.system.k3s.enable && config.modules.system.nodeVmGuest.enable;
  host = config.networking.hostName;
  state = "/persist/node-rollout";
  lcm = config.services.lcm;
  transferNetwork = lcm.transportTLS.transferNetwork or null;
  # The router-path VIP gateways (lcm's docs/router-path.md): a DaemonSet,
  # which a drain leaves alone, so the VIP would only move at kubelet's
  # shutdown, mid-reboot.
  vipSelector = "app=lcm-gateway-vip";
  # Only its own namespace: a pod elsewhere carrying the label must not be
  # able to answer for (or stall) the handoff.
  vipNamespace = "minecraft-gw";
  # Ceph warnings that don't stand in the way: crash reports linger for two
  # weeks. Beyond these, a warning known to be harmless can be muted
  # (`ceph health mute <CHECK> <ttl>`): ceph_ok skips muted checks.
  allowedChecks = [
    "RECENT_CRASH"
    "RECENT_MGR_MODULE_CRASH"
  ];
  inputs =
    with pkgs;
    [
      config.services.k3s.package
      coreutils
      curl
      diffutils
      jq
      systemd
    ]
    ++ lib.optional lcm.enable lcm.package;

  common = ''
    node=${host}
    state=${state}
    # Every request bounded: a stuck API server mustn't hang a step.
    k() { k3s kubectl --request-timeout=60s "$@"; }
    ceph() { k -n rook-ceph exec deploy/rook-ceph-tools -- ceph "$@"; }
    log() { printf 'node-rollout: %s\n' "$*" >&2; }
    die() { log "$*"; exit 1; }

    ceph_ok() {
      ceph health detail -f json 2>/dev/null \
        | jq -e --argjson allow '${builtins.toJSON allowedChecks}' \
          '[.checks // {} | to_entries[] | select(.value.muted != true) | .key] - $allow | length == 0' >/dev/null
    }
    ceph_report() { ceph health detail 2>&1 | head -20 >&2 || true; }

    # Every node but this one Ready and schedulable.
    others_ok() {
      k get nodes -o json | jq -e --arg me "$node" '
        [.items[] | select(.metadata.name != $me)
          | select(.spec.unschedulable == true
              or ([.status.conditions[] | select(.type == "Ready")][0].status != "True"))]
        | length == 0' >/dev/null
    }

    # Up to $1 seconds for "$2 ..." to succeed (the API is away while k3s restarts).
    wait_for() {
      local secs=$1
      shift
      local until=$(($(date +%s) + secs))
      until "$@" >/dev/null 2>&1; do
        [ "$(date +%s)" -lt "$until" ] || return 1
        sleep 5
      done
    }
    node_ready() {
      [ "$(k get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]
    }
    cilium_ready() {
      k -n kube-system wait --for=condition=Ready pod -l k8s-app=cilium \
        --field-selector "spec.nodeName=$node" --timeout=10s
    }
    osds_up() {
      ceph osd stat -f json | jq -e '.num_up_osds == .num_osds and .num_in_osds == .num_osds'
    }

    ${import ./lcm-drain.nix}

    # This node's VIP gateways, "NAMESPACE/POD IP ADMIN-PORT READY" a line
    # (hostNetwork: the pod IP is the node's), "-" for a missing IP or port:
    # read splits on runs of whitespace, so an empty field would shift the rest.
    vip_gateways() {
      k get pods -n ${vipNamespace} -l ${vipSelector} --field-selector "spec.nodeName=$node,status.phase=Running" -o json \
        | jq -r '.items[] | [.metadata.namespace + "/" + .metadata.name, (.status.podIP // "-"),
            ([.spec.containers[].ports[]? | select(.name == "admin") | .containerPort][0] // "-" | tostring),
            ([.status.conditions[]? | select(.type == "Ready")][0].status == "True" | tostring)] | join(" ")'
    }
    # The gateway at $1:$2 answers that it doesn't hold the VIP (an error
    # isn't an answer; vip_handoff logs the first failed request, so this
    # one's polling stays quiet).
    vip_inactive() { curl -fsS --max-time 5 "http://$1:$2/vip" 2>/dev/null | jq -e '.active == false' >/dev/null; }
    # Asks gateway $1 ($2:$3) to hand the VIP to a standby (a no-op if it
    # doesn't hold it; 409 while no standby is ready), every 20 s, until it
    # says it no longer holds it or $4 seconds pass. A refusal is logged once.
    # A POST that times out may still have handed it over: GET /vip says.
    vip_handoff() {
      local name=$1 ip=$2 port=$3 deadline next=0 now out code rc logged=0
      deadline=$(($(date +%s) + $4))
      while :; do
        now=$(date +%s)
        if [ "$now" -ge "$next" ]; then
          rc=0
          out=$(curl -sS --max-time 30 -w '\n%{http_code}' -X POST "http://$ip:$port/vip/handoff" 2>&1) || rc=$?
          code=''${out##*$'\n'}
          if [ "$logged" = 0 ] && [ "$rc" = 28 ]; then
            log "$name: the handoff request timed out after 30 s; asking the gateway whether it still holds the VIP"
            logged=1
          elif [ "$logged" = 0 ] && [[ $code != 2* ]]; then
            log "$name: handoff refused ($code): $(printf '%s' "''${out%$'\n'*}" | head -c 300)"
            logged=1
          fi
          next=$(($(date +%s) + 20))
        fi
        vip_inactive "$ip" "$port" && return 0
        [ "$(date +%s)" -lt "$deadline" ] || return 1
        sleep 5
      done
    }
    # Hands every VIP gateway's VIP here to a standby, $1 seconds each. One
    # that isn't Ready (crashlooping, its admin port down) is skipped.
    hand_off_vips() {
      local secs=$1 gws name ip port ready rc=0
      gws=$(vip_gateways) || { log "couldn't list the VIP gateways"; return 1; }
      while read -r name ip port ready; do
        [ -n "$name" ] || continue
        if [ "$port" = - ] || [ "$ip" = - ]; then
          log "$name: no admin port or pod IP: can't ask it"
          rc=1
        elif [ "$ready" != true ]; then
          log "$name: not Ready, skipped (if it holds the VIP, the reboot drops its players)"
        elif vip_handoff "$name" "$ip" "$port" "$secs"; then
          log "$name: VIP not served here"
        else
          log "$name: still serves the VIP (no standby took it in $secs s)"
          rc=1
        fi
      done <<< "$gws"
      return "$rc"
    }

    holder() { k -n kube-system get lease node-rollout -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true; }
    release() {
      if [ "$(holder)" = "$node" ]; then
        k -n kube-system delete lease node-rollout --ignore-not-found >/dev/null
      fi
    }
  '';

  rollout = pkgs.writeShellApplication {
    name = "node-rollout";
    runtimeInputs = inputs;
    text = ''
      ${common}

      usage() {
        echo "usage: node-rollout [--reboot | --bounce] SYSTEM | status | abort" >&2
        echo "  SYSTEM: /nix/store/...-nixos-system-$node-..., what this node's machine pins" >&2
        exit 2
      }

      acquire() {
        if k -n kube-system create -f - >/dev/null 2>&1 <<EOF
      apiVersion: coordination.k8s.io/v1
      kind: Lease
      metadata:
        name: node-rollout
        namespace: kube-system
      spec:
        holderIdentity: $node
        acquireTime: $(date -u +%Y-%m-%dT%H:%M:%S.000000Z)
      EOF
        then
          return 0
        fi
        local h
        h=$(holder)
        [ "$h" = "$node" ] || die "''${h:-another node} is rolling out (kube-system/node-rollout): wait, or 'node-rollout abort' there"
      }

      status() {
        echo "lease:   $(holder)"
        if [ -e "$state/pending" ]; then
          echo "pending: $(cat "$state/pending")"
          systemctl status --no-pager --lines=5 node-rollout-finish.service || true
        fi
        if [ -e "$state/last" ]; then echo "last:    $(cat "$state/last")"; fi
        echo "booted:  $(readlink -f /run/booted-system)"
        echo "current: $(readlink -f /run/current-system)"
      }

      abort() {
        k uncordon "$node" || true
        if [ -e "$state/pending" ]; then
          ceph osd unset noout || true
          rm -f "$state/pending"
        fi
        release
        log "aborted: uncordoned, noout off if this set it, the lease released"
      }

      mode=safe
      case "''${1:-}" in
        status) status; exit 0 ;;
        abort) abort; exit 0 ;;
        --reboot) mode=reboot; shift ;;
        --bounce) mode=bounce; shift ;;
      esac
      [ "$#" = 1 ] || usage
      sys=$1

      # The machine's store is this one: a system it hasn't built isn't here.
      [[ "$sys" =~ ^/nix/store/[0-9a-z]{32}-nixos-system-${host}-[^/]+$ ]] \
        || die "$sys is not a system of $node"
      [ -x "$sys/bin/switch-to-configuration" ] \
        || die "$sys isn't in the machine's store: rebuild the machine (its pin) first"
      [ ! -e "$state/pending" ] || die "a reboot is still finishing ('node-rollout status')"

      same() { [ "$(readlink -f "$1")" = "$(readlink -f "$2")" ]; }
      if [ "$mode" = safe ]; then
        for f in kernel initrd kernel-modules; do
          same "/run/booted-system/$f" "$sys/$f" || mode=reboot
        done
        cmp -s /run/booted-system/kernel-params "$sys/kernel-params" || mode=reboot
        if [ "$mode" = safe ] && same /run/current-system "$sys"; then
          log "already on $sys"
          exit 0
        fi
      fi

      acquire
      # Until it's handed over (to the reboot's finish, or kept on a node a
      # switch left unwell), every exit releases the lease.
      keep=0
      trap '[ "$keep" = 1 ] || release' EXIT

      if [ "$mode" != bounce ]; then
        others_ok || die "another node isn't Ready, or is cordoned"
        ceph_ok || { ceph_report; die "Ceph isn't healthy"; }
      fi

      if [ "$mode" = safe ]; then
        log "same kernel: switching live to $sys"
        keep=1
        "$sys/bin/switch-to-configuration" test || die "the switch failed; the lease is kept ('node-rollout abort' to release)"
        wait_for 600 node_ready || die "$node isn't Ready 10 minutes after the switch; the lease is kept"
        wait_for 300 cilium_ready || die "Cilium isn't Ready on $node; the lease is kept"
        wait_for 900 ceph_ok || { ceph_report; die "Ceph isn't healthy 15 minutes after the switch; the lease is kept"; }
        keep=0
        echo "$(date -u +%FT%TZ) switched to $sys" > "$state/last"
        log "done"
        exit 0
      fi

      mkdir -p "$state"
      if [ "$mode" = reboot ]; then
        log "draining, then rebooting into $sys"
        k cordon "$node"
        ${lib.optionalString lcm.enable ''
          # Before the drain: mc-no-evict forbids evicting lcm pods, and a
          # migration keeps their players.
          log "live-migrating lcm pods off"
          export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
          ${lib.optionalString (
            (lcm.transportTLS.enable or false) && transferNetwork != null
          ) "export LCM_TRANSFER_NETWORK=${transferNetwork}"}
          if ! lcm_drain_by "$node" 900; then
            k uncordon "$node"
            die "not every lcm pod moved (none was cut short): uncordoned, nothing rebooted"
          fi
        ''}
        if ! k drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=900s; then
          k uncordon "$node"
          die "the drain didn't finish in 15 minutes (a PDB?): uncordoned, nothing rebooted"
        fi
        # Last, so the VIP is elsewhere when the node goes down. A reboot
        # without a standby to take it would drop every player on it.
        log "handing the router VIP to another node"
        if ! hand_off_vips 60; then
          k uncordon "$node"
          die "a VIP gateway here still serves the VIP: uncordoned, nothing rebooted"
        fi
        echo "$sys reboot" > "$state/pending"
        ceph osd set noout
      else
        log "bouncing into $sys: no drain, no health checks"
        hand_off_vips 15 || log "the VIP stays here: its gateway tries again at shutdown"
        echo "$sys bounce" > "$state/pending"
        ceph osd set noout || log "Ceph didn't answer: no noout"
      fi
      keep=1
      ${lib.optionalString config.modules.system.k3s.tailscaleServices ''
        # Before kubelet's shutdown stops Cilium under it (tailscale-serve's own
        # drain comes after that).
        log "leaving svc:k8s"
        ${lib.getExe config.services.tailscale.package} serve drain svc:k8s || log "tailscale serve drain failed"
      ''}
      log "rebooting; node-rollout-finish completes it at boot ('node-rollout status')"
      systemctl reboot
    '';
  };

  finish = pkgs.writeShellApplication {
    name = "node-rollout-finish";
    runtimeInputs = inputs;
    text = ''
      ${common}
      read -r want mode < "$state/pending"
      wait_for 1800 node_ready || die "$node isn't Ready 30 minutes after boot"
      wait_for 600 cilium_ready || die "Cilium isn't Ready on $node"
      k uncordon "$node"
      wait_for 1800 osds_up || { ceph_report; die "the OSDs aren't all up 30 minutes after boot; noout is still set"; }
      ceph osd unset noout || [ "$mode" = bounce ]
      # A bounce hands over once the node and its OSDs are back (the next
      # node's etcd and Ceph need this one up), not once Ceph is healthy.
      if [ "$mode" != bounce ]; then
        wait_for 1800 ceph_ok || { ceph_report; die "Ceph isn't healthy 30 minutes after boot"; }
      fi
      got=$(readlink -f /run/booted-system)
      rm -f "$state/pending"
      release
      if [ "$got" = "$want" ]; then
        echo "$(date -u +%FT%TZ) rebooted into $got" > "$state/last"
        log "done"
      else
        echo "$(date -u +%FT%TZ) booted $got, not $want: the machine pins another system" > "$state/last"
        die "booted $got, not $want: the machine pins another system (rebuild it)"
      fi
    '';
  };
in
{
  config = lib.mkIf enable (
    lib.mkMerge [
      {
        environment.systemPackages = [ rollout ];

        systemd.services.node-rollout-finish = {
          description = "Finish a node-rollout reboot";
          wantedBy = [ "multi-user.target" ];
          after = [ "k3s.service" ];
          wants = [ "k3s.service" ];
          unitConfig.ConditionPathExists = "${state}/pending";
          # Its one run is at the reboot's boot; a switch mustn't start it.
          restartIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe finish;
            TimeoutStartSec = "2h";
          };
        };
      }
      # For agents: root templates, so always a human's approval.
      (lib.optionalAttrs (options.services ? agent-auth-hostd) {
        services.agent-auth-hostd.templates =
          let
            system = "^/nix/store/[0-9a-z]{32}-nixos-system-${host}-[0-9A-Za-z._+-]+$";
          in
          {
            node-rollout = {
              tier = "root";
              argv = [
                "node-rollout"
                "{system}"
              ];
              params = { inherit system; };
            };
            node-rollout-reboot = {
              tier = "root";
              argv = [
                "node-rollout"
                "--reboot"
                "{system}"
              ];
              params = { inherit system; };
            };
            node-rollout-bounce = {
              tier = "root";
              argv = [
                "node-rollout"
                "--bounce"
                "{system}"
              ];
              params = { inherit system; };
            };
            node-rollout-status = {
              tier = "root";
              argv = [
                "node-rollout"
                "status"
              ];
            };
            node-rollout-abort = {
              tier = "root";
              argv = [
                "node-rollout"
                "abort"
              ];
            };
          };
      })
    ]
  );
}
