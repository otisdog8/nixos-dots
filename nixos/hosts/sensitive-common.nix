# The sensitive cluster's servers: one VM per machine, beside the main node
# (hosts/<machine>-hv runs both, modules/system/node-vm.nix). Each
# hosts/<machine>-sensitive is this file and its machine's name.
#
# Nothing an agent reaches runs here, and nothing here reports to the main
# cluster: no hostd, no agent VM, no agent-auth client, no journal shipping
# (its VictoriaLogs is main's), no node-exporter of the fleet's (the
# cluster's own DaemonSet takes over). ssh as jrt alone, by key, over the
# tailnet alone (modules/system/k3s-sensitive.nix's firewall).
#
# Bootstrap, per machine, by hand on <machine>-hv (sudo):
#   1. lvcreate -L 32G -n sensitive vg; lvcreate -L 8G -n sensitive-swap vg;
#      lvcreate -L 200G -n sensitive-data vg
#   2. mkfs.btrfs -L sensitive /dev/vg/sensitive, and in it the subvolumes
#      root, persist, large, cache, dots; mkswap /dev/vg/sensitive-swap;
#      mkfs.xfs -L sensitive-data /dev/vg/sensitive-data
#   3. The guest's ssh host key, made where it stays: ssh-keygen -t ed25519
#      -N "" -f <persist>/etc/ssh/ssh_host_ed25519_key (persist mounted from
#      step 2). Its public key, through ssh-to-age, is the guest's sops
#      recipient (.sops.yaml).
#   4. A one-off Tailscale auth key tagged tag:sensitive (not reusable, not
#      ephemeral, pre-approved) at <persist>/tailscale.authkey; deleted
#      after the first login.
#   5. Rebuild the machine; `sudo node-vm start sensitive`. The guest logs
#      into the tailnet; put its address in tailnetIps below.
# Once all three addresses are in, k3s starts with the next rebuild and
# `sudo node-vm restart sensitive` (arquitens's first: it starts the
# cluster), with the token from sensitive-k3s-token.yaml (sops: the three
# guests' keys and Jacob's age key; `token: <random>`).
{
  config,
  inputs,
  lib,
  ...
}:
let
  cfg = config.modules.system.sensitiveGuest;

  # Each guest's tailnet address, after its first login (bootstrap, step 5).
  tailnetIps = {
    arquitens = null;
    carrack = null;
    munificent = null;
  };
  ready = lib.all (ip: ip != null) (lib.attrValues tailnetIps);

  # jrt's own machines' keys (remote-access.nix's), not the root ones.
  jrtKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICPtgHM9vEd6NR70wKznoP/HE3aCrud/9rx/2Lu16Dh4 jrt@excelsior"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKrESH5ZwJ9UprxxlPHlwMTLZtNiFysHR+5CHcTA63+a jrt@constitution"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID8cRRtLtbuTMeLNvA4oB1Ui0yk0yhdPTPBvqku6lQZj jrt@galaxy"
  ];
in
{
  imports = [
    inputs.sops-nix.nixosModules.sops
    ./sensitive-disks.nix

    inputs.nixos-hardware.nixosModules.common-pc-ssd

    ../modules/desktop/full
    ../modules/system/k3s-sensitive.nix
  ];

  options.modules.system.sensitiveGuest.machine = lib.mkOption {
    type = lib.types.enum (lib.attrNames tailnetIps);
    description = "The machine this guest runs on.";
  };

  config = {
    networking.hostName = "${cfg.machine}-sensitive";
    time.timeZone = "America/Los_Angeles";

    boot.supportedFilesystems = [ "btrfs" ];

    modules = {
      desktop.full.enable = false;
      # Booted by the machine, its store over virtio-fs (node-vm.nix).
      system.nodeVmGuest.enable = true;
      system.secureboot.enable = false;
      system.virt.enable = false;
      system.developer-tools.enable = false;
      system.zswap.enable = true;
      system.hardening = {
        enable = true;
        profile = "k3s-node";
        blacklistAfAlg = true;
      };

      system.journal-shipping.enable = false;
      system.node-exporter.enable = false;
      apps.agent-auth-client.enable = false;
      agentAuth.hostCommands = {
        user.enable = false;
        root.enable = false;
      };

      system.k3sSensitive = lib.mkIf ready {
        enable = true;
        nodeIp = tailnetIps.${cfg.machine};
        serverIps = lib.attrValues tailnetIps;
        clusterInit = cfg.machine == "arquitens";
        serverAddr = if cfg.machine == "arquitens" then null else "https://${tailnetIps.arquitens}:6443";
        tokenSopsFile = ./sensitive-k3s-token.yaml;
      };
    };

    services.agent-auth-hostd.enable = lib.mkForce false;

    services.openssh.settings = {
      PasswordAuthentication = lib.mkForce false;
      KbdInteractiveAuthentication = lib.mkForce false;
      PermitRootLogin = lib.mkForce "no";
      AllowUsers = lib.mkForce [ "jrt" ];
    };
    users.users.root.openssh.authorizedKeys.keys = lib.mkForce [ ];
    users.users.jrt.openssh.authorizedKeys.keys = lib.mkForce jrtKeys;

    # First login only (bootstrap, step 4); the tag comes with the key.
    services.tailscale.authKeyFile = "/persist/tailscale.authkey";

    # The guest's age identity is its ssh host key (bootstrap, step 3).
    sops.age.sshKeyPaths = [ "/persist/etc/ssh/ssh_host_ed25519_key" ];
    sops.gnupg.sshKeyPaths = [ ];
  };
}
