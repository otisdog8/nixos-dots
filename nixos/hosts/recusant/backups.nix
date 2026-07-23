# Recusant snapshot + off-site backup configuration.
#
# ── Borg (borgbase) ──────────────────────────────────────────────────────────
# Mirrors galaxy/excelsior: passphrase and repo URL both live in sops so
# neither lands in the world-readable nix store — borgmatic reads the
# passphrase at runtime via encryption_passcommand, and the repo path is a
# ''${BORG_REPO} placeholder interpolated from the environment (sops secret
# supplied to the unit as an EnvironmentFile). Only /persist is backed up
# (the module default); `mc` is covered by local snapshots only.
#
# sops base config (defaultSopsFile + host age key) lives in ./default.nix;
# this file only declares the secrets it consumes.
#
# ── One-time bootstrap on recusant ───────────────────────────────────────────
#   1. Add root's SSH pubkey (/root/.ssh/id_*.pub — /root/.ssh is persisted;
#      generate one if missing) as an access key on the borgbase repo.
#   2. First run, as root (accepts the repo host key into /root/.ssh/known_hosts
#      and initializes the repo; source the env file so ''${BORG_REPO} resolves):
#        set -a; . /run/secrets/borg-repo-env; set +a
#        borgmatic init --encryption repokey-blake2
#        borgmatic --verbosity 1
#   3. Export the repo key somewhere safe (borgbase can't recover it):
#        borg key export "$BORG_REPO"
{ config, ... }:
{
  imports = [
    ../../modules/system/snapshots.nix
    ../../modules/system/backups.nix
  ];

  # Enable BTRFS snapshots. `persist` holds all impermanence-backed service state
  # (garage, attic, agent-auth, hindsight, host keys, secret.jwe, …), so hourly
  # snapshots give point-in-time recovery for the whole host; `mc` covers the
  # minecraft world. Both are top-level subvolumes (see disks.nix). Snapshots land
  # in /mnt/btrfs_root/btrbk_snapshots per the module default.
  modules.system.snapshots = {
    enable = true;
    subvolumes = [
      "persist"
      "mc"
    ];
  };

  sops.secrets."borg-passphrase" = { };
  # Single line of the form BORG_REPO=ssh://... — dotenv-style so it can be
  # consumed directly as a systemd EnvironmentFile.
  sops.secrets."borg-repo-env" = { };

  modules.system.backups.enable = true;

  services.borgmatic.settings = {
    repositories = [
      {
        # Literal ''${BORG_REPO} in the rendered YAML; borgmatic resolves it
        # from the unit environment at runtime.
        path = "\${BORG_REPO}";
        label = "borgbase";
      }
    ];
    encryption_passcommand = "cat ${config.sops.secrets."borg-passphrase".path}";
  };

  systemd.services.borgmatic.serviceConfig.EnvironmentFile = [
    config.sops.secrets."borg-repo-env".path
  ];
}
