# agent-auth's daemons (agent-auth's docs/sandbox-design.md), both pinned to
# the same broker key:
#   - hostd, on every host: dials out to the broker on recusant, pairs once per
#     host. Where the agent VM runs it freezes the VM on lockdown and runs
#     approved commands as the user (the user tier; the root tier is off). It
#     decides itself what runs, from this config, its own TOTP secrets
#     (`sudo agent-auth-hostd totp-enroll`, once per host) and its arm state.
#     On desktops its helper in the user's session shows approval prompts
#     while the user is there (presence: hypridle's hooks);
#   - sandboxd, inside the agent VM (modules.agentVm's guest): runs the VM's
#     agents (headless claude/codex per conversation), routes their a2a.
#
# Inert until both exist:
#   - the agent-auth flake input provides the modules (push agent-auth, then
#     `nix flake update agent-auth`);
#   - `brokerPublicKey` below is set: the broker's public signing key, from
#     `agent-auth admin broker-key` once BROKER_SIGNING_KEY is in recusant's
#     agent-auth/env secret. Pinned here, in an audited commit, so no network
#     path can substitute another broker.
# Then pair, once each (the code is entered at the prompt, never as an
# argument: it would land in shell history):
#   hostd:    `agent-auth admin daemon-pair <host>`, then on the host
#             `sudo agent-auth-hostd pair`
#   sandboxd: `agent-auth admin daemon-pair --role sandbox <host>`, then on the
#             host `avm pair`
{
  config,
  inputs,
  lib,
  options,
  username,
  ...
}:
let
  brokerPublicKey = "ed25519:CAGm4HjX5-lT9w2JNi7U1yomf5i7u8Sge5G7o0eNWpY"; # "ed25519:…"
  brokerUrl = "https://agent-auth.recusant.rooty.dev";
  modules = inputs.agent-auth.nixosModules or { };
  pinned = brokerPublicKey != null;
  hostName = config.networking.hostName;
  hostd = config.services.agent-auth-hostd;
  # The pinned agent-auth may predate hostd's local policy (tiers, the VM's
  # unit, desktop prompts): those settings wait for the flake update.
  hostdPolicy = (options.services.agent-auth-hostd or { }) ? tiers;
  # As agent-auth's module: with a tier or a VM to freeze, hostd runs as root.
  hostdOwner =
    if hostdPolicy && (hostd.tiers.user.enable || hostd.tiers.root.enable || hostd.vm.unit != null) then
      "root"
    else
      "agent-auth-hostd";
  hypridle = config.modules.desktop.full.hyprland.hypridle;
in
{
  # Conditional on the input, never on config (imports can't depend on it).
  imports = lib.optional (modules ? hostd) modules.hostd;

  config = lib.mkMerge [
    (lib.optionalAttrs (modules ? hostd && pinned) {
      services.agent-auth-hostd = {
        enable = lib.mkDefault true;
        inherit brokerUrl brokerPublicKey;
      };
      # The host's identity key (lose it and the host must pair again) and
      # its TOTP secrets. Owned by whoever the service runs as (agent-auth's
      # hostd module), as its tmpfiles rules and StateDirectory expect.
      environment.persistence."/persist".directories = [
        {
          directory = "/var/lib/agent-auth-hostd";
          user = hostdOwner;
          group = hostdOwner;
          mode = "0700";
        }
      ];
    })
    (lib.optionalAttrs (modules ? hostd && pinned && hostdPolicy) {
      services.agent-auth-hostd = {
        user = lib.mkDefault username;
        # Lockdown freezes the agent VM.
        vm.unit = lib.mkIf config.modules.agentVm.enable (lib.mkDefault "agent-vm.service");
        # Commands as the user, where the agents are (bring-up, as the VM).
        # Nothing runs before `totp-enroll`, or while the tier is disarmed
        # (no autoCommands here). Root tier: off.
        tiers.user.enable = lib.mkDefault config.modules.agentVm.enable;
        # Time-boxed shells as the user (each opened with a TOTP code, every
        # command shown on Discord first): excelsior only, for bring-up. Here
        # and not in the host's file: the option may not exist yet.
        tiers.user.shell.enable = lib.mkDefault (hostName == "excelsior" && hostd.tiers.user.enable);
        desktop.enable = lib.mkDefault hypridle.enable;
      };
      # hypridle and the lock screen tell hostd whether the user is there
      # (Hyprland keeps no logind idle or lock hints).
      modules.desktop.full.hyprland.hypridle.presenceCommand = lib.mkIf hostd.desktop.enable (
        lib.mkDefault "/run/current-system/sw/bin/agent-auth-hostctl presence"
      );
    })
    (lib.optionalAttrs (modules ? sandboxd && pinned) {
      modules.agentVm.guestModules = [
        modules.sandboxd
        (
          { pkgs, ... }:
          {
            services.agent-auth-sandboxd = {
              enable = true;
              inherit brokerUrl brokerPublicKey hostName;
              # The plain packages, not the nixpak launchers (`claude` on the
              # host is a sandbox wrapper; the VM is the sandbox here).
              runtimes = {
                claude.package = pkgs.unstable-small.claude-code;
                codex.package = pkgs.unstable-small.codex;
              };
            };
          }
        )
      ];
    })
  ];
}
