# Off-site borg backups for excelsior (borgbase), replacing the old git-crypt
# secrets.nix. Both the passphrase and the repo URL are managed by sops-nix so
# neither lands in the world-readable nix store: borgmatic reads the passphrase
# at runtime via encryption_passcommand, and the repo path is a ''${BORG_REPO}
# placeholder that borgmatic interpolates from the environment — supplied to
# the systemd unit as an EnvironmentFile drop-in.
#
# sops base config (defaultSopsFile + host age key) lives in ./default.nix;
# this file only declares the secrets it consumes.
#
# ── One-time bootstrap on excelsior ──────────────────────────────────────────
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
    ../../modules/system/backups.nix
  ];

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
