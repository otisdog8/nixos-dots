# `nix run .#rollout -- [--reboot | --bounce] TARGET...` from any checkout
# (recusant's, galaxy's, excelsior's: whichever has git-crypt unlocked).
#
# - A k3s node (arquitens, carrack, munificent; "nodes" is all three):
#   its machine (<node>-hv) is rebuilt first, which pins the node's new
#   system and never restarts it; then the node rolls itself onto it with
#   node-rollout (modules/system/k3s/rollout.nix): a live switch, or a
#   drain and a reboot when the kernel changed (--reboot forces that;
#   --bounce reboots without draining or checking health). Machines first,
#   then the nodes one at a time, each waited for to the end.
# - Any other host: nixos-rebuild switch on it. --reboot or --bounce
#   reboots it afterwards; without either, it only says when the new kernel
#   needs one. A machine (*-hv) isn't rebooted here: that reboots its node
#   too, unannounced. Roll its node with --reboot after a hypervisor kernel
#   change instead (the VM restarts with the machine's next boot).
#
# Hosts are reached over ssh by name (ROLLOUT_SSH_SUFFIX is appended, e.g.
# ".tail-net.ts.net"); sudo asks for the password on each.
{ pkgs, self }:
pkgs.writeShellApplication {
  name = "rollout";
  runtimeInputs = with pkgs; [
    coreutils
    nixos-rebuild-ng
    openssh
  ];
  text = ''
    flake=''${FLAKE:-${self}}
    suffix=''${ROLLOUT_SSH_SUFFIX:-}
    nodes=(arquitens carrack munificent)
    log() { printf '\033[1mrollout: %s\033[0m\n' "$*" >&2; }
    die() { log "$*"; exit 1; }
    usage() {
      echo "usage: rollout [--reboot | --bounce] TARGET...   (TARGET: nodes, a node, or any host)" >&2
      exit 2
    }

    mode=""
    case "''${1:-}" in
      --reboot | --bounce) mode=$1; shift ;;
    esac
    [ "$#" -gt 0 ] || usage

    is_node() { local n; for n in "''${nodes[@]}"; do [ "$1" = "$n" ] && return 0; done; return 1; }
    # remote HOST [-ssh-option...] COMMAND...: ssh takes options before the
    # host only. This host runs it here.
    remote() {
      local h=$1 opts=()
      shift
      while [[ "''${1:-}" == -* ]]; do opts+=("$1"); shift; done
      # The arguments are expanded here on purpose (store paths, flags).
      # shellcheck disable=SC2029
      if [ "$h" = "$(hostname)" ]; then "$@"; else ssh "''${opts[@]}" "$h$suffix" "$@"; fi
    }

    deploy() {
      local h=$1
      log "$h: switching"
      if [ "$h" = "$(hostname)" ]; then
        sudo nixos-rebuild switch --flake "$flake#$h"
      else
        nixos-rebuild switch --flake "$flake#$h" --target-host "$h$suffix" --sudo --ask-sudo-password
      fi
    }

    host() {
      local h=$1
      deploy "$h"
      local booted current
      booted=$(remote "$h" readlink -f /run/booted-system/kernel)
      current=$(remote "$h" readlink -f /run/current-system/kernel)
      if [ -z "$mode" ]; then
        [ "$booted" = "$current" ] || log "$h: its new kernel needs a reboot (not done: --reboot)"
        return 0
      fi
      case "$h" in
        *-hv) log "$h: not rebooted (it would take its node down unannounced): roll the node with --reboot"; return 0 ;;
        "$(hostname)") log "$h: this host; reboot it yourself"; return 0 ;;
      esac
      log "$h: rebooting"
      remote "$h" -t sudo systemctl reboot || true
      sleep 20
      until remote "$h" -oConnectTimeout=5 true 2>/dev/null; do sleep 10; done
      log "$h: back, $(remote "$h" readlink -f /run/booted-system)"
    }

    node() {
      local n=$1 sys
      sys=$(nix build --no-link --print-out-paths "$flake#nixosConfigurations.$n-node.config.system.build.toplevel")
      log "$n: rolling onto $sys''${mode:+ ($mode)}"
      local before rc=0
      before=$(remote "$n" cat /persist/node-rollout/last 2>/dev/null || true)
      # 255: ssh lost the node, as when it reboots itself.
      # The target system's own node-rollout: the first rollout has none on
      # PATH yet, and the tool always matches what it installs.
      remote "$n" -t sudo "$sys/sw/bin/node-rollout" ''${mode:+"$mode"} "$sys" || rc=$?
      [ "$rc" = 0 ] || [ "$rc" = 255 ] || die "$n: node-rollout failed ($rc)"
      # A reboot finishes at boot (node-rollout-finish); wait for that.
      if [ "$rc" = 255 ] || [ -n "$mode" ] || remote "$n" test -e /persist/node-rollout/pending 2>/dev/null; then
        sleep 30
        until remote "$n" -oConnectTimeout=5 test ! -e /persist/node-rollout/pending 2>/dev/null; do
          if remote "$n" -oConnectTimeout=5 systemctl is-failed --quiet node-rollout-finish 2>/dev/null; then
            remote "$n" journalctl -u node-rollout-finish -n 20 --no-pager || true
            die "$n: node-rollout-finish failed (see above; 'sudo node-rollout abort' there once it's fixed)"
          fi
          sleep 15
        done
      fi
      local after
      after=$(remote "$n" cat /persist/node-rollout/last 2>/dev/null || true)
      if [ "$after" = "$before" ] && [ "$(remote "$n" readlink -f /run/current-system)" != "$sys" ]; then
        die "$n: nothing changed (is it on $sys? 'sudo node-rollout status' there)"
      fi
      log "$n: ''${after:-already on it}"
    }

    targets=()
    for t in "$@"; do
      if [ "$t" = nodes ]; then targets+=("''${nodes[@]}"); else targets+=("$t"); fi
    done
    # Every machine of a node in the list first: they don't disturb the
    # nodes, and each node then has its new system to roll onto.
    for t in "''${targets[@]}"; do
      if is_node "$t"; then deploy "$t-hv"; fi
    done
    for t in "''${targets[@]}"; do
      if is_node "$t"; then node "$t"; else host "$t"; fi
    done
    log "all done"
  '';
}
