# none backend — no sandbox.
#
# Emits the raw package under its original name and lowers app.storage at the
# home location (host-visible via impermanence). apps.nix forces `forceHome` for
# this backend, so storage.homePersistence carries every entry and tmpfilesRules
# is empty.
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
{
  # Unsandboxed: no session-bus filter to hand the VM implementation.
  dbusArgs = null;
  flatpakInfoFile = null;
  package = cfg.package;
  systemConfig = {
    systemd.tmpfiles.rules = storage.tmpfilesRules;
    environment.persistence = storage.homePersistence;
    assertions = storage.assertions;
  };
}
