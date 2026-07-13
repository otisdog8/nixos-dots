# Resolve app.storage entries into backend-agnostic pieces.
#
# Layer-1 storage is a list of { path; tier; location; type; mode; } entries.
# This turns each entry into:
#   - entries:         the resolved list, each with an effective `location` and
#                      its on-disk `stashPath` (/<tier>/sandbox/<app>/<path>).
#   - tmpfilesRules:   systemd-tmpfiles rules that create the stash dirs (stash
#                      entries only) — mandatory because bwrap `--bind-try` does
#                      NOT create a missing source.
#   - homePersistence: environment.persistence fragments for location = "home".
#
# Location semantics:
#   stash → data at /<tier>/sandbox/<app>/<path>; the sandbox binds it to ~/<path>.
#   home  → data at ~/<path> via impermanence (host-visible); bound as-is.
# `forceHome` (from the global toggle, or backend = "none") rewrites every entry
# to "home".
#
# Ownership / the per-app lock. The per-app root AND every intermediate dir are
# ROOT-owned; only the leaf is owned by the app principal. This is deliberate:
# systemd-tmpfiles refuses to create a file whose path traverses a dir owned by an
# unprivileged user ("unsafe path transition"), so a jrt-owned app-root would make
# the jrt-owned leaf uncreatable. Root-owned parents sidestep that AND give the
# per-app lock for free:
#   user      → app-root 0711 root (traversable → jrt reaches its own 0700 leaf;
#               rootless nixpak, not host-hidden by design)
#   root      → app-root 0700 root (LOCK: unsandboxed jrt can't traverse; systemd
#               same-uid stash), leaf jrt:users
#   dedicated → app-root 0700 root (LOCK), leaf app-<name>:app-<name>
# The shared /<tier>/sandbox parent is 0711 root, declared once in
# modules/system/sandbox.nix.
{ lib }:
{
  appName,
  appCfg,
  username ? "jrt",
  stashOwner ? "user",
  forceHome ? false,
}:
let
  tierMount = {
    persist = "/persist";
    large = "/large";
    cache = "/cache";
  };

  resolve =
    e:
    let
      loc = if forceHome then "home" else e.location;
    in
    e
    // {
      location = loc;
      stashPath = "${tierMount.${e.tier}}/sandbox/${appName}/${e.path}";
    };

  entries = map resolve appCfg.storage;
  stashEntries = lib.filter (e: e.location == "stash") entries;
  homeEntries = lib.filter (e: e.location == "home") entries;

  # Root-owned app-root + intermediates; app-root mode carries the per-app lock.
  appDirMode = if stashOwner == "user" then "0711" else "0700";
  leafOwner = if stashOwner == "dedicated" then "app-${appName}" else username;
  leafGroup = if stashOwner == "dedicated" then "app-${appName}" else "users";

  # Cumulative directory paths under `base` for the given path components.
  cumul = base: comps: lib.foldl' (acc: c: acc ++ [ "${lib.last acc}/${c}" ]) [ base ] comps;

  # systemd-tmpfiles splits rule columns on whitespace, so a space in a path
  # (Electron's "Code Cache") must be C-escaped or the rule is silently malformed
  # and the stash dir is never created. The mount/mv paths use the raw form.
  escT = lib.replaceStrings [ " " ] [ "\\x20" ];

  # Rules for one stash entry: root-owned intermediate dirs + the leaf.
  mkEntryRules =
    e:
    let
      appRoot = "${tierMount.${e.tier}}/sandbox/${appName}";
      comps = lib.filter (c: c != "") (lib.splitString "/" e.path);
      # Intermediate dirs = every path component except the final leaf (which is
      # the leaf dir, or the file itself). Root-owned; the leaf carries app perms.
      innerDirs = if comps == [ ] then [ ] else lib.init comps;
      interPaths = lib.tail (cumul appRoot innerDirs); # excludes appRoot itself
      interRules = map (p: "d ${escT p} ${appDirMode} root root -") interPaths;
      leafPath = "${appRoot}/${e.path}";
      leafRule =
        if e.type == "file" then
          "f ${escT leafPath} ${e.mode} ${leafOwner} ${leafGroup} -"
        else
          "d ${escT leafPath} ${e.mode} ${leafOwner} ${leafGroup} -";
    in
    interRules ++ [ leafRule ];

  stashTiers = lib.unique (map (e: e.tier) stashEntries);
  appRootRules = map (t: "d ${tierMount.${t}}/sandbox/${appName} ${appDirMode} root root -") stashTiers;

  tmpfilesRules = lib.unique (appRootRules ++ lib.concatMap mkEntryRules stashEntries);

  # location = home → impermanence entries on the entry's tier.
  homePersistence =
    let
      mkTier =
        tier:
        let
          es = lib.filter (e: e.tier == tier) homeEntries;
          dirs = map (e: e.path) (lib.filter (e: e.type == "dir") es);
          files = map (e: e.path) (lib.filter (e: e.type == "file") es);
        in
        lib.optionalAttrs (es != [ ]) {
          "${tierMount.${tier}}".users.${username} = {
            directories = dirs;
            files = files;
          };
        };
    in
    lib.mkMerge (map mkTier [ "persist" "large" "cache" ]);

  # (#3) Parent-first ordering. Nested bind TARGETS (e.g. a chromium cache dir
  # inside a persisted profile) must bind parent-before-child, so backends bind in
  # this order. Sorting by path depth guarantees any parent precedes its child.
  pathDepth = p: lib.length (lib.filter (c: c != "") (lib.splitString "/" p));
  sortedEntries = lib.sort (a: b: pathDepth a.path < pathDepth b.path) entries;

  # (#2) Same-tier nesting is illegal: the inner leaf's path would traverse the
  # jrt-owned outer leaf and hit systemd-tmpfiles' unsafe-path-transition, so the
  # inner leaf is silently never created. Cross-tier nesting is fine (each tier is
  # a separate on-disk root with its own all-root intermediate chain).
  compsOf = p: lib.filter (c: c != "") (lib.splitString "/" p);
  strictPrefix =
    a: b:
    let
      ca = compsOf a;
      cb = compsOf b;
    in
    lib.length ca < lib.length cb && lib.take (lib.length ca) cb == ca;
  nestingMsgs = lib.concatMap (
    a:
    lib.concatMap (
      b:
      lib.optional (a.tier == b.tier && strictPrefix a.path b.path)
        "sandbox app '${appName}': storage paths '${a.path}' and '${b.path}' are nested on the same tier '${a.tier}'. systemd-tmpfiles cannot create the inner leaf (unsafe path transition through the jrt-owned outer leaf). Put them on different tiers, or merge into one entry."
    ) stashEntries
  ) stashEntries;
  # (#4) Validate storage paths: they feed root systemd-tmpfiles rules and root
  # bind mounts, so reject anything that isn't a normalized home-relative path —
  # no absolute paths, no '.'/'..' components, and only a conservative safe charset
  # (letters, digits, . _ - / and space; the space is \x20-escaped for tmpfiles).
  badPathMsgs = lib.concatMap (
    e:
    let
      comps = compsOf e.path;
      ok =
        e.path != ""
        && !(lib.hasPrefix "/" e.path)
        && !(lib.elem ".." comps)
        && !(lib.elem "." comps)
        && builtins.match "[a-zA-Z0-9._/ -]+" e.path != null;
    in
    lib.optional (
      !ok
    ) "sandbox app '${appName}': invalid storage path '${e.path}'. Must be a normalized home-relative path (no leading '/', no '.'/'..' components, chars in [A-Za-z0-9._/ -])."
  ) entries;
  assertions = map (m: {
    assertion = false;
    message = m;
  }) (nestingMsgs ++ badPathMsgs);
in
{
  inherit
    stashEntries
    homeEntries
    tmpfilesRules
    homePersistence
    assertions
    ;
  # Parent-first so nested bind targets mount in the right order (#3).
  entries = sortedEntries;
}
