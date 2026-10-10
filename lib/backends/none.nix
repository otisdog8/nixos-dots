# none backend — no sandbox.
#
# Emits the raw package under its original name and lowers app.storage at the
# home location (host-visible via impermanence). apps.nix forces `forceHome` for
# this backend, so storage.homePersistence carries every entry and tmpfilesRules
# is empty.
#
# With data to lock, the main command takes the container side of the app's
# implementation lock (lib/impl-lock.nix) before it runs: its VM works on the
# same ~ data.
{
  appName,
  appCfg,
  cfg,
  config,
  lib,
  pkgs,
  inputs,
  storage,
}:
let
  binName = appCfg.packageName;
  implLock = import ../impl-lock.nix { inherit lib pkgs; };
  lockHold = implLock.hold {
    cls = "container";
    apps = lib.optional (implLock.wanted {
      backend = "none";
      inherit (storage) entries;
      inherit (appCfg) multiInstance;
    }) appName;
    notify = true;
  };
  lockedLauncher = pkgs.writeShellScript "${appName}-locked" ''
    exec ${lockHold} ${cfg.package}/bin/${binName} "$@"
  '';
in
{
  # Unsandboxed: no session-bus filter to hand the VM implementation.
  dbusArgs = null;
  flatpakInfoFile = null;
  appId = null;
  package =
    if lockHold == "" then
      cfg.package
    else
      pkgs.symlinkJoin {
        inherit (cfg.package) name;
        paths = [ cfg.package ];
        postBuild = ''
          rm "$out/bin/${binName}"
          ln -s ${lockedLauncher} "$out/bin/${binName}"
          # Absolute Exec=/D-Bus service paths to the main program go through
          # the lock too.
          if [ -d "$out/share" ]; then
            { grep -RlF "${cfg.package}/bin/" "$out/share" || true; } | while IFS= read -r f; do
              t="$(readlink -f "$f")"
              rm "$f"
              sed "s|${cfg.package}/bin/|$out/bin/|g" "$t" > "$f"
            done
          fi
        '';
      };
  systemConfig = {
    systemd.tmpfiles.rules = storage.tmpfilesRules;
    environment.persistence = storage.homePersistence;
    assertions = storage.assertions;
  };
}
