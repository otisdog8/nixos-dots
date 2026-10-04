# agent-auth's host daemon on every host (agent-auth's docs/sandbox-design.md):
# it dials out to the broker on recusant, pairs once per host, and is what will
# run approved commands outside the agent VMs and freeze them on lockdown.
#
# Inert until both exist:
#   - the agent-auth flake input provides nixosModules.hostd (push agent-auth,
#     then `nix flake update agent-auth`);
#   - `brokerPublicKey` below is set: the broker's public signing key, from
#     `agent-auth admin broker-key` once BROKER_SIGNING_KEY is in recusant's
#     agent-auth/env secret. Pinned here, in an audited commit, so no network
#     path can substitute another broker.
# Then, per host: `agent-auth admin daemon-pair <host>` on the admin side, and
# on the host `sudo agent-auth-hostd pair`, entering the code at the prompt
# (never as an argument: it would land in shell history).
{
  config,
  inputs,
  lib,
  ...
}:
let
  brokerPublicKey = null; # "ed25519:…"
  available = inputs.agent-auth ? nixosModules && inputs.agent-auth.nixosModules ? hostd;
  active = available && brokerPublicKey != null;
in
{
  # Conditional on the input, never on config (imports can't depend on it).
  imports = lib.optional available inputs.agent-auth.nixosModules.hostd;

  config = lib.optionalAttrs active {
    services.agent-auth-hostd = {
      enable = lib.mkDefault true;
      brokerUrl = "https://agent-auth.recusant.rooty.dev";
      inherit brokerPublicKey;
    };
    # The host's identity key: lose it and the host must pair again. Owned by
    # the service's user (agent-auth's hostd module), as its tmpfiles rules and
    # StateDirectory expect; declared root-owned here, the two would disagree.
    environment.persistence."/persist".directories = [
      {
        directory = "/var/lib/agent-auth-hostd";
        user = "agent-auth-hostd";
        group = "agent-auth-hostd";
        mode = "0700";
      }
    ];
  };
}
