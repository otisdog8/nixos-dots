# Compressed swap via zswap (NOT zram) with server-appropriate tuning.
#
# Rationale (Chris Down, "zswap vs zram", 2026-03): zswap tiers cold pages to a
# real backing device with a dynamic shrinker, so it degrades gracefully instead
# of hitting a full-pool wall; and its memory IS cgroup-accounted, so it doesn't
# silently break the kubelet's per-pod memory isolation the way zram does.
#
# The backing swap device is a plain LV inside the host's LVM-on-LUKS VG, so it's
# already encrypted at rest — no randomEncryption / separate LUKS swap needed. It
# is declared per-host in that host's disks.nix (`content.type = "swap"`).
#
# Latency protection: the etcd/k3s system path runs in system.slice. We set
# memory.zswap.writeback=0 there so those (cold) pages compress in RAM but never
# reserve or hit the encrypted backing swap — keeping the fsync path clean —
# while bulk workloads (kubepods.slice, user.slice) still get full disk tiering.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.system.zswap;
in
{
  options.modules.system.zswap = {
    enable = lib.mkEnableOption "zswap compressed swap cache with server tuning";

    maxPoolPercent = lib.mkOption {
      type = lib.types.ints.between 1 50;
      default = 20;
      description = ''
        Ceiling (not reservation) on the percent of RAM zswap's compressed pool
        may occupy. Only what's needed is used; the cap protects page cache from
        zswap itself in a pathological low-compressibility case. 20% of 64 GiB =
        ~12.8 GiB, well above what a 16 GiB backing device needs at zstd ~3:1.
      '';
    };

    swappiness = lib.mkOption {
      type = lib.types.ints.between 0 200;
      default = 60;
      description = ''
        vm.swappiness. With compressed-in-RAM reclaim the cost of paging a cold
        page is cheap, so a non-trivial value is wanted or cold-anon eviction
        barely happens (which is the whole point). 60 (the kernel default) leans
        into that; writeback is disabled on the latency-sensitive slice anyway,
        so the etcd path never pays a disk cost for it.
      '';
    };

    minFreeKbytes = lib.mkOption {
      type = lib.types.int;
      default = 262144; # ~256 MiB
      description = ''
        vm.min_free_kbytes — kernel emergency reserve. A larger reserve makes the
        kernel reclaim earlier and cleaner under a sudden spike (Ceph recovery,
        rebuild backfill) rather than lurching toward the global OOM killer.
      '';
    };

    protectedSlices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "system.slice" ];
      description = ''
        cgroup v2 slices to disable zswap disk writeback on
        (memory.zswap.writeback = 0). Their cold pages stay compressed in RAM but
        never touch the encrypted backing swap. system.slice covers k3s + the
        embedded etcd; kubepods.slice / user.slice deliberately keep writeback.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # zswap is configured on the kernel command line so it's active from the very
    # first swapon. zsmalloc (densest zpool) + zstd (best ratio, trivial on the
    # AMD cores); shrinker_enabled turns on the dynamic writeback that keeps the
    # pool from filling and degrading badly.
    boot.kernelParams = [
      "zswap.enabled=1"
      "zswap.compressor=zstd"
      "zswap.zpool=zsmalloc"
      "zswap.max_pool_percent=${toString cfg.maxPoolPercent}"
      "zswap.shrinker_enabled=1"
    ];

    # Make sure the zpool/compressor backends exist even if the kernel ships them
    # as modules (params above would otherwise fall back at zswap init).
    boot.kernelModules = [
      "zsmalloc"
      "zstd"
    ];

    boot.kernel.sysctl = {
      # Override the global default (kernel.nix pins 10) — a host that opts into
      # zswap wants cold-anon eviction to actually happen.
      "vm.swappiness" = lib.mkForce cfg.swappiness;
      "vm.min_free_kbytes" = cfg.minFreeKbytes;
    };

    # There's no first-class systemd directive for memory.zswap.writeback, so
    # assert it once the slices exist. Setting it on the parent slice is inherited
    # by children (k3s.service, etc.) created later, so a single write suffices.
    systemd.services.zswap-writeback-protect = {
      description = "Disable zswap disk writeback on latency-sensitive cgroups";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = lib.concatMapStringsSep "\n" (slice: ''
        f=/sys/fs/cgroup/${slice}/memory.zswap.writeback
        if [ -w "$f" ]; then
          echo 0 > "$f" && echo "zswap writeback disabled on ${slice}"
        else
          echo "note: $f not writable/present (kernel <6.1 or controller off)" >&2
        fi
      '') cfg.protectedSlices;
    };
  };
}
