# Module-autoload census: every module the kernel itself asks for
# (request_module: socket families, netlink families, link kinds,
# filesystems, device nodes, qdiscs...) goes to the journal, tagged
# kmod-request, before kmod's modprobe runs with the same arguments; so do
# the tools that run /proc/sys/kernel/modprobe (nvidia-modprobe,
# libxtables). Not seen: udev's hotplug loads and systemd-modules-load (both
# libkmod, in process), nor an explicit modprobe or insmod.
# `journalctl -t kmod-request` over a few weeks shows what each role's
# kernel asks for.
#
# Phase 1 of an allowlist: phase 2 refuses names that aren't on a per-role
# list, built from this census.
#
# Only stage 2: the initrd keeps the kernel's default helper. It runs before
# anything untrusted and loads what boot.initrd lists; nothing there logs.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  enable = config.modules.system.hardening.enable && config.boot.modprobeConfig.enable;

  # Run by the kernel as root, with PATH=/sbin:/usr/sbin:/bin:/usr/bin and
  # HOME=/ (so store paths only), and also by whatever reads
  # /proc/sys/kernel/modprobe and runs it (nvidia-modprobe, libxtables) with
  # ordinary modprobe arguments. Those go to modprobe untouched, so install
  # and blacklist rules apply as before. Logging never stands in its way:
  # early in stage 2 there is no /dev/log, and journald can be stuck, so the
  # logger gets 2 seconds and its failure is ignored. The arguments are an
  # unprivileged caller's choice (a link kind, a filesystem name): data only,
  # never evaluated, control characters replaced, length capped.
  # bash -p: a setuid caller's euid survives into modprobe, as it did when
  # this was modprobe itself. logger turns the kern facility into user, so
  # user it is.
  wrapper = pkgs.writeScript "modprobe-census" ''
    #!${pkgs.runtimeShell} -p
    msg="$*"
    msg="''${msg//[^[:print:]]/?}"
    ${pkgs.coreutils}/bin/timeout 2 ${pkgs.util-linux}/bin/logger -t kmod-request -p user.info -- "''${msg:0:512}" </dev/null >/dev/null 2>&1 || :
    exec ${pkgs.kmod}/bin/modprobe "$@"
  '';
in
{
  config = lib.mkIf enable {
    # nixos/modules/system/boot/modprobe.nix writes kmod's modprobe here on
    # every activation; this writes the wrapper instead.
    system.activationScripts.modprobe = lib.mkForce (
      lib.stringAfter [ "specialfs" ] ''
        echo ${wrapper} > /proc/sys/kernel/modprobe
      ''
    );
    system.build.modprobeCensus = wrapper;
  };
}
