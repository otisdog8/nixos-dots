# Shell functions for taking the lcm pods off a node (rollout.nix,
# shutdown.nix), needing k3s, jq, coreutils and lcm on PATH.
#
# lcm_drain_by NODE SECONDS live-migrates the node's lcm pods off one at a
# time, as `lcm drain` does (the same pods: runtimeClassName lcm, Running and
# Ready, not being deleted; each to the node with the most memory free:
# --to auto), but starts none after SECONDS, and fails if any is left.
#
# Not `timeout … lcm drain`: lcm handles SIGINT only (SIGTERM kills it
# outright), and SIGINT cancels the context its fence and rollback run on
# (cmd/lcm/main.go, internal/controller/migrate.go), so either can leave a
# pod fenced or half-restored. Each migration is bounded inside lcm (3
# minutes for the destination to park, 2-6 for the restore, 15 to reconnect
# a broken stream), so this ends; it just never cuts one short.
''
  lcm_pods() {
    k3s kubectl --request-timeout=60s get pods -A --field-selector "spec.nodeName=$1" -o json | jq -r '
      .items[]
      | select(.spec.runtimeClassName == "lcm" and .metadata.deletionTimestamp == null
          and .status.phase == "Running"
          and ([.status.conditions[]? | select(.type == "Ready")][0].status == "True"))
      | "\(.metadata.namespace) \(.metadata.name)"'
  }
  lcm_drain_by() {
    local deadline pods ns pod left=0
    deadline=$(($(date +%s) + $2))
    pods=$(lcm_pods "$1") || return 1
    while read -r ns pod; do
      [ -n "$pod" ] || continue
      if [ "$(date +%s)" -ge "$deadline" ]; then
        printf 'lcm: %s/%s not started: past the deadline\n' "$ns" "$pod" >&2
        left=$((left + 1))
        continue
      fi
      lcm migrate "$pod" -n "$ns" --to auto </dev/null || left=$((left + 1))
    done <<< "$pods"
    [ "$left" = 0 ]
  }
''
