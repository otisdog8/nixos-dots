# Build the inner nixpak/bwrap-wrapped package from app.storage + features.
# Shared by the nixpak (in-session) and systemd (stash) backends.
#
#   stashAtHome = false → in-session nixpak: stash entries bind
#                         [stashPath -> ~/path] (jrt reaches the jrt-owned leaf
#                         through the 0711-root parents directly).
#   stashAtHome = true  → systemd backend: the root service has already grafted
#                         each stash leaf onto ~/path inside its private mount
#                         namespace, so the inner bwrap binds ~/path same-same
#                         (it must NOT touch the 0700-root stash path itself,
#                         which it can't traverse as jrt).
#
# Stash binds are HARD (--bind via bind.rwHard): the source is guaranteed by
# tmpfiles / the service, so a missing source must fail the sandbox loudly, not
# silently skip and run ephemeral.
{
  appCfg,
  cfg,
  lib,
  pkgs,
  inputs,
  storage,
  stashAtHome ? false,
  # When the app runs as a DIFFERENT uid than jrt (dedicated), relative extraBinds
  # (shared jrt data like a vault) must resolve against jrt's home literal, not the
  # app's own $HOME. null → resolve against $HOME (same-uid).
  sharedHome ? null,
  # Cross-uid document portal (dedicated only): a [src dst] pair binding the
  # runScript-relayed doc FUSE at jrt's IDENTITY path inside the sandbox, so the
  # doc:// paths the portal returns (jrt-absolute) resolve. null → same-uid, where
  # nixpak's own mountDocumentPortal already handles it. See lib/backends/systemd.nix.
  docBind ? null,
}:
let
  nixpakLib = inputs.nixpak or (builtins.throw "nixpak not available - add nixpak to flake inputs");
  mkNixPak = nixpakLib.lib.nixpak { inherit lib pkgs; };
in
let
  built = mkNixPak {
  config =
    {
      config,
      lib,
      pkgs,
      sloth,
      ...
    }:
    {
      # Layer-1 capabilities lowered to bwrap, alongside the raw-nixpakModules
      # escape hatch (both consumed by this bwrap lowering; they compose freely).
      imports =
        appCfg.nixpakModules
        ++ [ (import ../capabilities-nixpak.nix { inherit lib; } appCfg.capabilities) ]
        ++ cfg.sandbox.nixpakModules;

      app.package = cfg.package;
      app.binPath = "bin/${appCfg.packageName}";

      bubblewrap.network = lib.mkOverride 999 false;

      # Stash entries (parent-first from storage.entries) — hard bind.
      bubblewrap.bind.rwHard = map (
        e:
        if stashAtHome then
          sloth.concat' sloth.homeDir "/${e.path}"
        else
          [
            e.stashPath
            (sloth.concat' sloth.homeDir "/${e.path}")
          ]
      ) (lib.filter (e: e.location == "stash") storage.entries);

      bubblewrap.bind.rw =
        # home-located entries: same-path bind of the impermanence-mounted ~/path
        # (soft — may legitimately not exist yet).
        (map (e: sloth.concat' sloth.homeDir "/${e.path}") (
          lib.filter (e: e.location == "home") storage.entries
        ))
        # extra binds (legacy semantics; shared jrt data under dedicated uid).
        ++ (map (
          p:
          if lib.hasPrefix "/" p then
            p
          else if lib.hasPrefix "." p then
            sloth.concat' (sloth.env "PWD") "/${p}"
          else if sharedHome != null then
            "${sharedHome}/${p}"
          else
            sloth.concat' sloth.homeDir "/${p}"
        ) cfg.sandbox.extraBinds)
        # Cross-uid doc-portal identity bind (dedicated). Soft (--bind-try): the
        # runScript only relays it when jrt actually has a doc portal running.
        ++ lib.optional (docBind != null) docBind;
    };
  };
in
{
  package = built.config.env;
  # nixpak's generated .flatpak-info (Application name = the app-id, session-bus
  # policy). The systemd backend binds this onto the cross-uid bridge's /proc/root
  # so the portal identifies the dedicated app as sandboxed → hands out doc:// paths.
  flatpakInfoFile = built.config.flatpak.infoFile;
}
