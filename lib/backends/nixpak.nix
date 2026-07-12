# nixpak backend — in-session, rootless bwrap wrapper (today's behaviour), binds
# sourced from app.storage. Stash dirs are jrt-owned (stashOwner = "user"); the
# app runs as jrt in the session, so data isn't hidden from the host — nixpak's
# isolation is the sandbox boundary, not host-hiding.
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
  package = import ./nixpak-pkg.nix {
    inherit
      appCfg
      cfg
      lib
      pkgs
      inputs
      storage
      ;
    stashAtHome = false;
  };
  systemConfig = {
    systemd.tmpfiles.rules = storage.tmpfilesRules;
    environment.persistence = storage.homePersistence;
    assertions = storage.assertions;
    modules.sandbox.stashMigrations = lib.optional (storage.stashEntries != [ ]) {
      app = appName;
      bin = appCfg.packageName;
      user = builtins.head appCfg.defaultUsernames; # old-layout source (jrt)
      owner = builtins.head appCfg.defaultUsernames; # target ownership (jrt)
      entries = map (e: { inherit (e) tier path; }) storage.stashEntries;
    };
  };
}
