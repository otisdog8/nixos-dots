# Fleet-wide disk-health hygiene: periodic scrubs (btrfs + bcachefs), TRIM, and
# SMART monitoring. Enabled by default (see nixos/default.nix); every piece is a
# no-op on hosts that lack the relevant hardware/filesystem, so a single switch
# covers desktops, the k3s nodes, and recusant.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.system.storage-health;
  hasBcachefs = lib.any (fs: fs.fsType == "bcachefs") (builtins.attrValues config.fileSystems);
in
{
  options.modules.system.storage-health = {
    enable = lib.mkEnableOption "disk-health hygiene (scrubs, TRIM, SMART)";

    fstrim = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Weekly `fstrim` on discard-capable filesystems (no-op elsewhere).";
    };

    btrfsScrub = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Monthly `btrfs scrub` on every btrfs mount discovered in config.fileSystems.
        Auto-detected, so hosts with no btrfs get no units.
      '';
    };

    smart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "smartd SMART monitoring with device autodetect.";
    };

    bcachefsScrub = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Monthly `bcachefs scrub` via the upstream services.bcachefs.autoScrub,
        which auto-detects all bcachefs mounts. Only wired on hosts that actually
        have a bcachefs filesystem, so it's a no-op elsewhere.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (lib.mkIf cfg.fstrim {
        services.fstrim.enable = true;
      })

      # Auto-detects btrfs mounts from config.fileSystems; interval is a systemd
      # calendar spec. Runs `btrfs scrub` (checksum verification + repair from a
      # good copy where redundancy exists) so silent corruption surfaces before it
      # propagates into backups.
      (lib.mkIf cfg.btrfsScrub {
        services.btrfs.autoScrub = {
          enable = true;
          interval = "monthly";
        };
      })

      # smartd: background SMART polling + self-tests. `-a` = all attributes,
      # `-o on` runs offline data collection, `-s (S/../.././02|L/../../6/03)`
      # schedules a short self-test nightly at 02:00 and a long one Saturday 03:00.
      # Failures go to `wall` (root broadcast) and the journal; a push/mail hook
      # can be layered on later without touching this.
      (lib.mkIf cfg.smart {
        services.smartd = {
          enable = true;
          autodetect = true;
          notifications.wall.enable = true;
          defaults.monitored = "-a -o on -s (S/../.././02|L/../../6/03)";
        };
      })

      # Upstream bcachefs scrub (checksum verification + repair from a replica
      # where the pool has replication). Auto-detects mounts and picks the right
      # `bcachefs scrub`/`bcachefs data scrub` invocation for the tools version.
      # Only enabled where a bcachefs filesystem exists — the module asserts
      # enable -> fileSystems != [], so blanket-enabling would fail on other hosts.
      (lib.mkIf (cfg.bcachefsScrub && hasBcachefs) {
        services.bcachefs.autoScrub = {
          enable = true;
          interval = "monthly";
        };
      })
    ]
  );
}
