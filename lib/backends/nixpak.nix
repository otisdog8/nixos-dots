# nixpak backend — in-session, rootless bwrap wrapper (today's behaviour), but
# with binds sourced from app.storage instead of the legacy persistence.user.*
# lists. Stash dirs are jrt-owned (stashOwner = "user"); the app runs as jrt in
# the graphical session, so data is not hidden from the host — nixpak's isolation
# is the sandbox boundary, not host-hiding.
#
# This is the moved-and-generalised form of the mkNixPak block that used to live
# inline in lib/apps.nix.
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
  nixpakLib = inputs.nixpak or (builtins.throw "nixpak not available - add nixpak to flake inputs");
  mkNixPak = nixpakLib.lib.nixpak { inherit lib pkgs; };

  wrapped =
    (mkNixPak {
      config =
        {
          config,
          lib,
          pkgs,
          sloth,
          ...
        }:
        {
          # Feature-contributed modules first, per-host overrides second (same
          # merge semantics as before).
          imports = appCfg.nixpakModules ++ cfg.sandbox.nixpakModules;

          app.package = cfg.package;
          app.binPath = "bin/${appCfg.packageName}";

          # Network off unless a feature/capability turns it on.
          bubblewrap.network = lib.mkOverride 999 false;

          # Stash entries use a HARD bind (--bind): the source is guaranteed by
          # tmpfiles, so a missing source is a bug that must fail the sandbox
          # loudly rather than silently skip (--bind-try) and run ephemeral.
          # storage.entries is parent-first (#3), so nested stash targets bind in
          # order.
          bubblewrap.bind.rwHard = map (
            e:
            [
              e.stashPath
              (sloth.concat' sloth.homeDir "/${e.path}")
            ]
          ) (lib.filter (e: e.location == "stash") storage.entries);

          bubblewrap.bind.rw =
            # home-located entries: same-path bind of the impermanence-mounted
            # ~/path (soft: it may legitimately not exist yet on first boot).
            (map (e: sloth.concat' sloth.homeDir "/${e.path}") (
              lib.filter (e: e.location == "home") storage.entries
            ))
            # Extra binds (unchanged semantics from the legacy path).
            ++ (map (
              p:
              if lib.hasPrefix "/" p then
                p
              else if lib.hasPrefix "." p then
                sloth.concat' (sloth.env "PWD") "/${p}"
              else
                sloth.concat' sloth.homeDir "/${p}"
            ) cfg.sandbox.extraBinds);
        };
    }).config.env;
in
{
  package = wrapped;
  systemConfig = {
    systemd.tmpfiles.rules = storage.tmpfilesRules;
    environment.persistence = storage.homePersistence;
    assertions = storage.assertions;
  };
}
