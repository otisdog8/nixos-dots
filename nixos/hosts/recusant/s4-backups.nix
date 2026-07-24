# Off-site backups to MEGA S4 (S3-compatible object storage). Two independent
# jobs, both additive to backups.nix (borgmatic→borgbase still covers /persist;
# btrbk still does local snapshots) — this file is what gets the bcachefs pool
# and Garage's real data off-site, since neither has any other off-host copy
# (garage runs replication_factor = 1).
#
# ── restic → S4 bucket `recusant-restic` ─────────────────────────────────────
# Filesystem paths on the bcachefs pool:
#   /mnt/bcachefs/k8s/Immich   — the Immich library (k8s mounts it over NFS)
#   /mnt/bcachefs/backups      — staging dir; other hosts will later deposit
#                                their backups here and reach S4 "for free"
# restic gives client-side encryption + deduped snapshot history with
# forget/prune retention, so this leg has real versioning.
#
# ── rclone S3→S3 → S4 bucket `recusant-garage` ───────────────────────────────
# Mirrors the k8s-tenant Garage buckets (velero, cnpg-backups, gitea-rgw) —
# deliberately NOT nix-cache, which is a regenerable attic binary cache sharing
# the same Garage instance. This content is sensitive (cnpg WAL = full DB
# contents, velero backups can include k8s Secrets, gitea-rgw = repo data), so
# it goes through an rclone `crypt` wrapper remote: contents AND names are
# encrypted client-side (NaCl secretbox) before MEGA sees them — the S4-side
# bucket is opaque, and restore requires rclone + the crypt passwords from the
# sops env (obscured form; `rclone reveal` recovers the plaintext — the
# encrypted env file in git is the recovery copy). Logical layout per source
# bucket (physical names on S4 are encrypted):
#   recusant-garage/<bucket>/current/       — the mirror
#   recusant-garage/<bucket>/archive/DATE/  — history: any object a sync would
#                                             overwrite or delete is MOVED here
#                                             (--backup-dir), pruned after 90d
# Crypt trade-off: no MD5/ETag passthrough, so syncs compare size+modtime
# instead of checksums (fine — this data is write-once with unique names) and
# a full integrity re-verify needs `rclone check --download` (egress).
# Chosen over provider bucket-versioning: --backup-dir is provider-agnostic
# (S4's versioning/lifecycle support is undocumented), prunable with one flag,
# and restore is a plain copy. For append-mostly buckets (velero, cnpg WAL)
# the archive holds whatever their own retention deletes for another 90 days;
# for mutable gitea-rgw it's per-day object revisions. NOTE the flip side: if
# a Garage bucket is ever wiped, the next sync moves EVERYTHING into that
# day's archive — the 90-day window is the undo.
#
# ── One-time bootstrap ───────────────────────────────────────────────────────
#   1. MEGA S4 console — confirm the region first! rclone knows the
#      current-style endpoints (s3.ca-vancouver.megas4.com; legacy alias
#      s3.ca-west-1.s4.mega.io) — use whichever the console shows, and fix
#      s4Endpoint below if it differs. Then:
#        - create buckets: recusant-restic, recusant-garage
#        - create access key(s). Do NOT enable bucket versioning — history is
#          restic's / --backup-dir's job, provider versions would just grow
#          unpruned.
#   2. Garage (on recusant; buckets already exist, wired from k8s) — mint one
#      read-only sync key (read = list+get, all a sync source needs; the k8s
#      writers keep their own rw keys per the garage.nix tenancy model):
#        garage key create backup-sync-ro     # note Key ID + Secret
#        garage bucket allow --read velero       --key backup-sync-ro
#        garage bucket allow --read cnpg-backups --key backup-sync-ro
#        garage bucket allow --read gitea-rgw    --key backup-sync-ro
#   3. Secrets. secrets/s4-backups.yaml already holds a generated
#      restic-s4-password (the encrypted file in git IS the recovery copy —
#      decryptable via the recusant/galaxy/constitution host keys) and a
#      restic-s4-repo of s3:https://s3.ca-vancouver.megas4.com/recusant-restic;
#      edit the repo URL only if the console region differs (step 1).
#      secrets/s4-backups.env already holds generated crypt passwords
#      (RCLONE_CONFIG_S4CRYPT_PASSWORD/PASSWORD2, rclone-obscured — same
#      recovery model; NEVER rotate these once data is uploaded or the mirror
#      becomes unreadable). Fill its CHANGE_ME placeholders with the real keys:
#        sops nixos/hosts/recusant/secrets/s4-backups.env
#          AWS_ACCESS_KEY_ID=<S4 key id, restic>
#          AWS_SECRET_ACCESS_KEY=<S4 secret, restic>
#          RCLONE_CONFIG_GARAGE_ACCESS_KEY_ID=<backup-sync-ro key id>
#          RCLONE_CONFIG_GARAGE_SECRET_ACCESS_KEY=<backup-sync-ro secret>
#          RCLONE_CONFIG_S4_ACCESS_KEY_ID=<S4 key id, rclone>
#          RCLONE_CONFIG_S4_SECRET_ACCESS_KEY=<S4 secret, rclone>
#      (restic's and rclone's S4 credentials are separate vars even if they
#      start as the same key, so they can be rotated/scoped independently.)
#   4. Rebuild, then first runs by hand:
#        systemctl start restic-backups-s4.service   # slow: full Immich upload
#        systemctl start rclone-garage-s4.service
#      Verify: restic-s4 snapshots      (module wrapper on PATH, run as root)
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Garage S3 API on the tailnet — same endpoint attic.nix consumes.
  garageEndpoint = "http://100.110.239.45:3900";
  # Confirm against the S4 console (bootstrap step 1) — region may differ.
  s4Endpoint = "https://s3.ca-vancouver.megas4.com";
  s4Bucket = "recusant-garage";
  # Garage buckets to mirror. Adding one: append here + `garage bucket allow
  # --read <bucket> --key backup-sync-ro` on recusant.
  garageBuckets = [
    "velero"
    "cnpg-backups"
    "gitea-rgw"
  ];
  # How long overwritten/deleted objects survive in archive/ — the undo window.
  archiveMaxAge = "90d";
in
{
  # ── Secrets ─────────────────────────────────────────────────────────────────
  # Both restic keys live in their own sops yaml (NOT the host defaultSopsFile):
  # sops-nix validates key presence at BUILD time, and a fresh file can be
  # created/encrypted with only the recipients' public keys — recusant.yaml
  # would need a private host key to edit. Recovery model matches borg: the
  # encrypted file in git, decryptable by three host keys, is the off-host copy
  # of the repo password.
  sops.secrets."restic-s4-password".sopsFile = ./secrets/s4-backups.yaml;
  # s3:https://s3.<region>.megas4.com/recusant-restic — in sops like BORG_REPO
  # so no endpoint/bucket details land in the world-readable store.
  sops.secrets."restic-s4-repo".sopsFile = ./secrets/s4-backups.yaml;
  # Whole-file dotenv shared by both units — restic ignores the RCLONE_* vars
  # and vice versa. No restartUnits: both consumers are oneshot timer jobs that
  # read the file fresh on every start.
  sops.secrets."s4-backups/env" = {
    format = "dotenv";
    sopsFile = ./secrets/s4-backups.env;
    key = "";
  };

  # Staging dir other hosts will deposit into. Same caveat as the garage data
  # dir rules in garage.nix: tmpfiles needs the (nofail) mount present.
  systemd.tmpfiles.rules = [
    "d /mnt/bcachefs/backups 0755 root root - -"
  ];

  # ── restic → S4 ─────────────────────────────────────────────────────────────
  services.restic.backups.s4 = {
    repositoryFile = config.sops.secrets."restic-s4-repo".path;
    passwordFile = config.sops.secrets."restic-s4-password".path;
    # AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY for the S3 backend.
    environmentFile = config.sops.secrets."s4-backups/env".path;
    # `restic cat config || restic init` on every start — creates the repo
    # inside the (pre-existing) bucket on first run, no-ops after.
    initialize = true;
    paths = [
      "/mnt/bcachefs/k8s/Immich"
      "/mnt/bcachefs/backups"
    ];
    pruneOpts = [
      "--keep-daily 14"
      "--keep-weekly 8"
      "--keep-monthly 12"
    ];
    # Structural (metadata-only) repo check after each run. For an occasional
    # data spot-check add "--read-data-subset=1%" to checkOpts — costs egress.
    runCheck = true;
    timerConfig = {
      OnCalendar = "03:00";
      RandomizedDelaySec = "1h";
      Persistent = true;
    };
  };

  # /mnt/bcachefs is nofail: without gating, a boot with the HDD missing would
  # back up two empty dirs and record that as the newest snapshot state.
  # RequiresMountsFor fails the unit loudly; the Condition is belt-and-braces.
  systemd.services."restic-backups-s4".unitConfig = {
    RequiresMountsFor = [ "/mnt/bcachefs" ];
    ConditionPathIsMountPoint = "/mnt/bcachefs";
  };

  # The module pins RESTIC_CACHE_DIR=/var/cache/restic-backups-s4, and /var is
  # ephemeral on this host — persist it or every reboot re-downloads the repo
  # index/metadata from S4. Runs as root (no DynamicUser), so a plain path
  # works; no /var/lib/private dance like garage needed.
  environment.persistence."/persist".directories = [
    {
      directory = "/var/cache/restic-backups-s4";
      mode = "0700";
    }
  ];

  # ── rclone Garage → S4 ──────────────────────────────────────────────────────
  # Remotes are defined purely via env vars — no rclone.conf anywhere (rclone
  # logs a one-line NOTICE about the missing config file; harmless). Non-secret
  # halves live here (world-readable in the store, fine); the four credentials
  # come from the sops dotenv (EnvironmentFile is loaded by root before the
  # DynamicUser drop, same as garage.nix). Remote names are UPPERCASE so the
  # CLI names match the env-var spelling exactly.
  systemd.services.rclone-garage-s4 = {
    description = "Sync Garage k8s buckets to MEGA S4";
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "garage.service"
    ];
    path = [
      pkgs.rclone
      pkgs.coreutils
    ];
    environment = {
      # DynamicUser has no home and the sandbox has no getent, so rclone can't
      # resolve its default config/cache dirs (it logs a startup ERROR triple
      # and falls back to cwd=/, read-only under ProtectSystem=strict). We are
      # deliberately configless — pin the config to /dev/null and give the
      # cache/home fallbacks the unit-private /tmp.
      RCLONE_CONFIG = "/dev/null";
      HOME = "/tmp";
      RCLONE_CONFIG_GARAGE_TYPE = "s3";
      # rclone has no Garage provider; "Other" is the documented choice.
      RCLONE_CONFIG_GARAGE_PROVIDER = "Other";
      RCLONE_CONFIG_GARAGE_ENDPOINT = garageEndpoint;
      RCLONE_CONFIG_GARAGE_REGION = "garage";
      RCLONE_CONFIG_GARAGE_FORCE_PATH_STYLE = "true";
      RCLONE_CONFIG_S4_TYPE = "s3";
      RCLONE_CONFIG_S4_PROVIDER = "Mega";
      RCLONE_CONFIG_S4_ENDPOINT = s4Endpoint;
      RCLONE_CONFIG_S4_FORCE_PATH_STYLE = "true";
      # The S4 key is bucket-scoped and its policy denies CreateBucket. rclone
      # otherwise tries a bucket-existence Mkdir (= CreateBucket) on the first
      # write of each remote instance — the --backup-dir instance hit this with
      # a 403 on every archive move, so overwrites/deletes could never archive
      # and the sync failed each run. no_check_bucket is rclone's switch for
      # exactly this restricted-key setup; the bucket pre-exists (bootstrap 1).
      RCLONE_CONFIG_S4_NO_CHECK_BUCKET = "true";
      # If SigV4 errors mention a region mismatch, additionally set
      # RCLONE_CONFIG_S4_REGION to the region id the S4 console shows.
      # Client-side encryption layer over the S4 bucket — contents and names
      # (default "standard" filename encryption). The two passwords come from
      # the sops dotenv (S4CRYPT_PASSWORD/PASSWORD2, obscured form).
      RCLONE_CONFIG_S4CRYPT_TYPE = "crypt";
      RCLONE_CONFIG_S4CRYPT_REMOTE = "S4:${s4Bucket}";
    };
    # One sync + prune per bucket, all through the S4CRYPT wrapper. A failing
    # bucket must not skip the rest, so collect failures and exit non-zero at
    # the end — the unit reports failure while every healthy bucket still
    # synced. No --checksum: crypt can't pass MD5/ETags through, so rclone
    # compares size+modtime (crypt preserves original modtimes in metadata).
    # --log-level INFO + per-phase exit codes: rclone was observed exiting
    # non-zero with NOTHING logged at the default NOTICE level, so surface
    # everything. rclone exit codes: 3=dir not found, 5=temporary error,
    # 6=less-serious errors, 7=fatal. (rc capture via ||: the NixOS script
    # wrapper runs under set -e, so a bare failing command would abort the
    # whole loop.)
    script = ''
      fail=0
      for bucket in ${lib.escapeShellArgs garageBuckets}; do
        rc=0
        rclone sync "GARAGE:$bucket" "S4CRYPT:$bucket/current" \
          --backup-dir "S4CRYPT:$bucket/archive/$(date +%F)" \
          --fast-list --transfers 8 \
          --log-level INFO --stats 1m --stats-log-level NOTICE || rc=$?
        if [ "$rc" -ne 0 ]; then
          echo "sync of bucket $bucket failed (rclone exit $rc)" >&2
          fail=1
        fi
        # Age out the archive; --rmdirs clears the emptied date dirs.
        rc=0
        rclone delete "S4CRYPT:$bucket/archive" \
          --min-age ${archiveMaxAge} --rmdirs --log-level INFO || rc=$?
        if [ "$rc" -ne 0 ]; then
          echo "archive prune of bucket $bucket failed (rclone exit $rc)" >&2
          fail=1
        fi
      done
      exit $fail
    '';
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = config.sops.secrets."s4-backups/env".path;
      # Pure network client (S3→S3, no fs access) → same full DynamicUser
      # lockdown as mc-monitor (minecraft.nix).
      DynamicUser = true;
      NoNewPrivileges = true;
      CapabilityBoundingSet = [ "" ];
      # AF_UNIX is NOT optional: rclone detects systemd via $JOURNAL_STREAM and
      # logs to the native journald socket (a unix datagram socket) instead of
      # stderr — without AF_UNIX every log line after startup is silently
      # dropped at connect(), which made failing syncs completely mute.
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
    };
    # No mount gating (unlike restic above): both ends are network. If Garage
    # is down the run fails visibly, which is exactly right.
  };

  systemd.timers.rclone-garage-s4 = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Offset from restic (03:00 + up to 1h jitter) so the uplink isn't shared.
      OnCalendar = "04:30";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };
}
