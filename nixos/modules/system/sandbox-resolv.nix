# sbx-resolv: a resolv.conf for the containers that follows resolved's.
#
# nixpak binds /etc/resolv.conf into every container with network
# (`--ro-bind-try`, following the symlink to resolved's stub-resolv.conf), so a
# container holds that file's inode for as long as it runs. resolved replaces
# the file on every DNS change (a Wi-Fi reconnect, Tailscale going up or down),
# and the container's copy is then a deleted file: still readable (with the old
# search domains), but nothing can bind it again, so a nested bwrap fails to
# start: Steam's pressure-vessel ("Can't bind mount /oldroot/.host-etc/
# resolv.conf on /newroot/etc/resolv.conf"), and with it every game and
# Steam's web helper.
#
# Here the stub file is copied into a file of our own, rewritten in place on
# each change so its inode lasts, and capabilities-nixpak.nix binds that over
# /etc/resolv.conf instead. (A container started before the copy exists keeps
# nixpak's bind, as before.)
{
  config,
  lib,
  pkgs,
  ...
}:
let
  stub = "/run/systemd/resolve/stub-resolv.conf";
  copy = "/run/sbx-resolv/resolv.conf";

  # Only when the content changed. The write truncates first, so a reader can
  # see the file empty for that instant (a resolver reading it then falls back
  # to 127.0.0.1 for the one lookup); a rename would leave the containers on a
  # deleted file again.
  update = pkgs.writeShellScript "sbx-resolv-update" ''
    set -eu
    content=$(${pkgs.coreutils}/bin/cat ${stub})
    if [ "$content" != "$(${pkgs.coreutils}/bin/cat ${copy} 2>/dev/null || true)" ]; then
      printf '%s\n' "$content" >${copy}
    fi
  '';
in
{
  config = lib.mkIf config.services.resolved.enable {
    systemd.services.sbx-resolv = {
      description = "Sandbox resolv.conf (follows resolved's stub)";
      after = [ "systemd-resolved.service" ];
      wants = [ "systemd-resolved.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = update;
        RuntimeDirectory = "sbx-resolv";
        RuntimeDirectoryMode = "0755";
        # The copy is what running containers have bound: keep it (and its
        # inode) when this oneshot finishes or restarts.
        RuntimeDirectoryPreserve = true;
        UMask = "0022";
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateNetwork = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        RestrictAddressFamilies = "none";
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" ];
        MemoryDenyWriteExecute = true;
      };
    };

    systemd.paths.sbx-resolv = {
      description = "Watch resolved's stub-resolv.conf for the sandboxes";
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathChanged = stub;
    };
  };
}
