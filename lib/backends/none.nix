# none backend — no sandbox.
#
# Emits the raw package under its original name and lowers app.storage at the
# home location (host-visible via impermanence). The v2 expression of the old
# `sandbox.enable = false`, but still composed through the Layer-1 module system.
# apps.nix forces `forceHome` for this backend, so storage.homePersistence carries
# every entry and tmpfilesRules is empty.
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
  package = cfg.package;
  systemConfig = {
    systemd.tmpfiles.rules = storage.tmpfilesRules;
    environment.persistence = storage.homePersistence;
    assertions = storage.assertions;
  };
}
