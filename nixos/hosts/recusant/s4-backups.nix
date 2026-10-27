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
# Mirrors the k8s-tenant Garage buckets (velero, cnpg-backups, gitea-rgw,
# and the sensitive cluster's sensitive-cnpg-*, already ciphertext) —
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
    # The sensitive cluster's database backups (garage.nix): encrypted
    # before they reach Garage, so S4CRYPT encrypts them a second time.
    "sensitive-cnpg-broker"
    "sensitive-cnpg-litellm"
  ];
  # How long overwritten/deleted objects survive in archive/ — the undo window.
  # Days (int), not an rclone age string: the prune keys on the archive DATE
  # directory, not file modtime (see the prune loop for why --min-age was wrong).
  archiveMaxAgeDays = 90;
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
      # Minecraft worlds used to live here too, but were split into their own
      # `restic.backups.mc` job below — see that job for why (HDD-gating + snapshot
      # consistency).
    ];
    # Tag this job's snapshots so `forget`'s keep-policy only ages THESE — the mc job
    # shares the same repo and prunes its own `mc` tag independently. --retry-lock
    # makes a run WAIT OUT (rather than fail against) a lock held by the mc job or the
    # monthly drill instead of erroring "repository is already locked".
    extraBackupArgs = [
      "--tag=s4"
      "--retry-lock=15m"
    ];
    pruneOpts = [
      "--tag=s4"
      "--keep-daily 14"
      "--keep-weekly 8"
      "--keep-monthly 12"
      "--retry-lock=15m"
    ];
    # Structural (metadata-only) repo check after each run, over the WHOLE repo (so it
    # covers the mc job's data too). For an occasional data spot-check the monthly
    # drill pulls --read-data-subset — costs egress.
    checkOpts = [ "--retry-lock=15m" ];
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

  # ── restic /mc → S4 (own job, shared repo) ───────────────────────────────────
  # Minecraft worlds — the only off-host copy (btrbk snapshots share the same single
  # NVMe pool, so a pool loss takes worlds + history together). Split out of the s4
  # job above for two reasons:
  #   1. Gating: the s4 job is gated on the /mnt/bcachefs HDD (Immich/backups live
  #      there). /mc lives on the always-present NVMe root pool, so folding it into
  #      that job meant a missing HDD SILENTLY skipped the worlds too (a condition
  #      skip is `inactive`, not `failed`, so it never paged). This job isn't gated
  #      on the HDD, so worlds back up regardless of the media disk.
  #   2. Consistency: worlds are backed up from the latest btrbk SNAPSHOT, not the
  #      live /mc, so restic captures a frozen, internally-consistent point-in-time
  #      view (no torn region files while the servers are mid-write).
  # Same repo/bucket/password as s4; a per-job --tag scopes each job's forget policy
  # to its own snapshots. The s4 job's structural check + the monthly drill's
  # read-data-subset both run over the shared repo and cover this job's data, so
  # there's no second exclusive `restic check` here.
  services.restic.backups.mc = {
    repositoryFile = config.sops.secrets."restic-s4-repo".path;
    passwordFile = config.sops.secrets."restic-s4-password".path;
    environmentFile = config.sops.secrets."s4-backups/env".path;
    initialize = true;
    # Newest btrbk snapshot of the mc subvol. btrbk names them mc.<YYYYMMDDThhmm> (a
    # fixed-width UTC stamp, so lexical sort == chronological), landing in
    # /mnt/btrfs_root/btrbk_snapshots (snapshots.nix default). Fail loudly if none
    # exists yet rather than silently backing up nothing. Needs a shebang: the restic
    # module execs this script directly (writeScript adds none).
    dynamicFilesFrom = ''
      #!${pkgs.runtimeShell}
      set -euo pipefail
      latest=$(${pkgs.coreutils}/bin/ls -1d /mnt/btrfs_root/btrbk_snapshots/mc.* 2>/dev/null \
        | ${pkgs.coreutils}/bin/sort \
        | ${pkgs.coreutils}/bin/tail -n1 || true)
      if [ -z "$latest" ]; then
        echo "restic mc backup: no btrbk snapshot under /mnt/btrfs_root/btrbk_snapshots (mc.*)" >&2
        exit 1
      fi
      echo "$latest"
    '';
    extraBackupArgs = [
      "--tag=mc"
      "--retry-lock=15m"
    ];
    pruneOpts = [
      "--tag=mc"
      # Group the mc series by HOST, overriding restic's default `host,paths`. The
      # backed-up path is the btrbk snapshot dir mc.<YYYYMMDDThhmm>, which is UNIQUE
      # per run — under the default grouping every snapshot would be its own group of
      # one and the keep-policy would prune NOTHING, growing the repo without bound.
      # All mc snapshots share host=recusant (and the --tag=mc filter already scopes
      # forget to this series), so grouping by host treats them as one retention set.
      "--group-by=host"
      "--keep-daily 14"
      "--keep-weekly 8"
      "--keep-monthly 12"
      "--retry-lock=15m"
    ];
    # No runCheck: the s4 job's check + the monthly drill cover the shared repo; a
    # second exclusive check would only add lock contention.
    runCheck = false;
    timerConfig = {
      # Ahead of the s4 backup (03:00) so their exclusive forget/prune locks don't
      # stack; --retry-lock absorbs any residual overlap.
      OnCalendar = "02:00";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };

  # /mc is on the NVMe root pool (always present), NOT the bcachefs HDD, so this job
  # is deliberately NOT gated on /mnt/bcachefs — decoupling worlds from the media
  # disk is the whole point of splitting it out. It reads btrbk snapshots under
  # /mnt/btrfs_root.
  systemd.services."restic-backups-mc".unitConfig = {
    RequiresMountsFor = [ "/mnt/btrfs_root" ];
  };

  # The module pins RESTIC_CACHE_DIR=/var/cache/restic-backups-<name>, and /var is
  # ephemeral on this host — persist it or every reboot re-downloads the repo
  # index/metadata from S4. Runs as root (no DynamicUser), so a plain path
  # works; no /var/lib/private dance like garage needed.
  environment.persistence."/persist".directories = [
    {
      directory = "/var/cache/restic-backups-s4";
      mode = "0700";
    }
    {
      directory = "/var/cache/restic-backups-mc";
      mode = "0700";
    }
  ];

  # ── restic restore DRILL ─────────────────────────────────────────────────────
  # Proves the off-site repo is actually RESTORABLE, not merely that backups run
  # (the classic untested-backup trap). On ANY failure the unit exits non-zero and
  # enters `failed`, which the k8s Prometheus systemd-unit alerting already scrapes
  # off recusant's node-exporter — so a broken/undecryptable/empty repo pages
  # instead of being discovered the day it's needed. Two checks:
  #   1. snapshots exist (catches a backup that silently stopped landing);
  #   2. `restic check --read-data-subset=1%` pulls a random 1% of PACK DATA from S4
  #      and verifies it decrypts + hashes clean — the real "the key opens real
  #      data" proof that the metadata-only runCheck on the backup can't give, at
  #      bounded egress. This IS the restore-path exercise: it reads, decrypts and
  #      hashes real repo data. A full `restic restore` isn't used because the
  #      largest source (/mc worlds) is >100 GB — restoring it would blow the unit's
  #      tmpfs PrivateTmp and pull the whole tree from S4 every month.
  # Reuses the backup's repo/password/creds and its PERSISTED cache (so it doesn't
  # re-pull the whole index each run). Pulls FROM S4 only → no local-mount gating,
  # so unlike the backup it still runs (and can still verify history) when the
  # bcachefs HDD is absent.
  systemd.services.restic-restore-drill-s4 = {
    description = "Restore drill: verify the S4 restic repo is restorable";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [
      pkgs.restic
      pkgs.coreutils
      pkgs.gnugrep
    ];
    environment = {
      RESTIC_REPOSITORY_FILE = config.sops.secrets."restic-s4-repo".path;
      RESTIC_PASSWORD_FILE = config.sops.secrets."restic-s4-password".path;
      # Share the backup's persisted index/metadata cache (root-owned 0700).
      RESTIC_CACHE_DIR = "/var/cache/restic-backups-s4";
    };
    serviceConfig = {
      Type = "oneshot";
      # AWS_* creds for the S3 backend (same dotenv the backup uses).
      EnvironmentFile = config.sops.secrets."s4-backups/env".path;
      # Runs as root (default): needs the 0700 root-owned restic cache the backup
      # persists. PrivateTmp isolates whatever scratch `restic check` writes.
      PrivateTmp = true;
    };
    script = ''
      set -euo pipefail
      # ONE snapshots call: the assignment fails loudly under set -e on a repo that's
      # unreachable / wrong-key / missing-cred, and its captured output feeds the
      # presence check below. Do NOT `restic snapshots --json | grep -q`: grep -q
      # exits at the first match, and once the JSON tops the pipe buffer restic dies
      # on SIGPIPE (exit 141) which pipefail would turn into a FALSE "NO snapshots"
      # failure on a healthy repo. --retry-lock waits out the backup/drill locks.
      snapshots_json="$(restic --retry-lock=15m snapshots --json)"
      # 1. Backups must actually exist.
      if ! ${pkgs.gnugrep}/bin/grep -q '"short_id"' <<<"$snapshots_json"; then
        echo "restore drill: NO snapshots in the S4 repo — backups are not landing" >&2
        exit 1
      fi
      # 2. Data-integrity + restore-path proof: pull, decrypt and hash-verify a random
      #    1% of pack data from S4 (see the header for why this replaces a full /mc
      #    restore).
      restic --retry-lock=15m check --read-data-subset=1%
      echo "restore drill OK: snapshots present, 1% pack data pulled + verified clean"
    '';
  };
  systemd.timers.restic-restore-drill-s4 = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # First of the month at midday, deliberately clear of the backup windows (mc
      # 02:00±30m, s4 03:00±1h, rclone 04:30±30m). The drill's `restic check` takes an
      # EXCLUSIVE repo lock, so keeping it off the 02:00–05:00 band — plus --retry-lock
      # in the script — avoids a lock collision that would fail either the drill or a
      # backup and page spuriously. Monthly bounds the 1%-read egress while still
      # catching a repo that has gone bad well before it's actually needed.
      OnCalendar = "*-*-01 12:00:00";
      RandomizedDelaySec = "2h";
      Persistent = true;
    };
  };

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
        # Age out the archive BY DATE DIRECTORY, not by file modtime. The S4CRYPT
        # remote preserves each object's ORIGINAL modtime, so `rclone delete
        # --min-age` measured age from when the object was first written — often
        # long before it was archived — and deleted freshly-archived history on
        # the very next run, gutting the ${toString archiveMaxAgeDays}-day undo
        # window this leg exists for (the bucket-wipe recovery scenario). The sync
        # above lays the archive out as archive/<YYYY-MM-DD>/ (its `date +%F`), so
        # prune whole date dirs whose date is older than the cutoff. lsf sees the
        # plaintext date names through the crypt remote.
        cutoff=$(date -d '${toString archiveMaxAgeDays} days ago' +%Y%m%d)
        rc=0
        archive_days=$(rclone lsf --dirs-only "S4CRYPT:$bucket/archive/" 2>/dev/null) || rc=$?
        if [ "$rc" -eq 3 ]; then
          : # exit 3 = directory not found: no archive dir yet (nothing overwritten
            # or deleted has ever been synced) — nothing to prune.
        elif [ "$rc" -ne 0 ]; then
          echo "archive list of bucket $bucket failed (rclone exit $rc)" >&2
          fail=1
        else
          for d in $archive_days; do
            day=''${d%/}
            # Only ever touch YYYY-MM-DD dirs; skip anything unexpected in archive/.
            case "$day" in
              [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
              *) continue ;;
            esac
            # Lexical/numeric compare of YYYYMMDD (dashes stripped) — ISO dates
            # order chronologically, so "older than cutoff" is a plain <.
            [ "''${day//-/}" -lt "$cutoff" ] || continue
            prc=0
            rclone purge "S4CRYPT:$bucket/archive/$day" --log-level INFO || prc=$?
            if [ "$prc" -ne 0 ]; then
              echo "archive prune of $bucket/archive/$day failed (rclone exit $prc)" >&2
              fail=1
            fi
          done
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
