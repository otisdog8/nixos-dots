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
  # Dedicated apps proxy D-Bus through the jrt-side bridge, which is where the filter
  # belongs — it's the trusted-uid boundary, and it avoids chaining two
  # xdg-dbus-proxy --filter instances (that breaks: see systemd.nix). true → run
  # nixpak's INNER proxy TRANSPARENT (no --filter); the bridge filters instead.
  transparentDbus ? false,
  # Dedicated only: expose jrt's X socket (/tmp/.X11-unix) + DISPLAY to the sandbox so
  # the app can use XWayland. Auth is granted by the launcher's xhost. See
  # nixos/modules/apps/xwayland-forward.md.
  x11Forward ? false,
  # Per-app shared downloads (dedicated only): bind jrt's ~/Downloads/<app> in AS the
  # app's ~/Downloads, so saved files land host-visible under a per-app subdir instead
  # of the app's hidden home. null → off. Value is the app name (the subdir).
  sharedDownloads ? null,
  # Host override for the gpu capability's device-node list
  # (modules.sandbox.gpuDevices). null → capabilities-nixpak.nix default (all GPUs).
  gpuDevices ? null,
  # The sandbox broker's socket for this sandbox (modules/system/sandbox-broker.nix),
  # relative to the sandbox's $XDG_RUNTIME_DIR; bound at /run/sbx/broker.sock.
  # Soft: absent when the broker isn't running. null → none.
  brokerSocketName ? null,
  # The broker's filtered PulseAudio socket for this sandbox, relative to
  # $XDG_RUNTIME_DIR, bound over pulse/native (same-uid apps, whose runtime dir
  # is the user's own). null → the sandbox's own pulse/native as is (the systemd
  # backend relays the filtered socket there itself).
  pulseSocketName ? null,
  # systemd + dedicatedUser + sandbox.appearAsUser: the app runs as app-<name> but
  # sees itself as the user. { uid; gid; home; oldHome; } — bwrap maps the app's
  # uid/gid to the user's, the runScript has put the app's home at the user's
  # home (`home`) in its mount namespace, and the app's previous home path
  # (`oldHome`) stays bound to the same data for paths saved before. sharedHome
  # is then the runScript's stage of the user's real home. null → off.
  identity ? null,
}:
let
  nixpakSrc = inputs.nixpak or (builtins.throw "nixpak not available - add nixpak to flake inputs");
  # nixpak hardcodes `--filter` on its inner proxy (modules/launch.nix). Patch the
  # source to gate it on a new `dbus.filter` option (default true), so the inner
  # proxy can run transparently for dedicated apps. nixpak's lib is `import ./modules`
  # (flake.lib.nixpak), so we import the patched modules the same way.
  patchedNixpak = pkgs.applyPatches {
    name = "nixpak-dbus-filter-toggle";
    src = nixpakSrc;
    postPatch = ''
      substituteInPlace modules/dbus.nix --replace-fail \
        'mountDocumentPortal = mkOption {' \
        'filter = mkOption { default = true; type = bool; description = "Apply xdg-dbus-proxy --filter (deny-by-default); off = transparent relay."; }; mountDocumentPortal = mkOption {'
      substituteInPlace modules/launch.nix --replace-fail \
        '++ config.dbus.args ++ [ "--filter" ];' \
        '++ config.dbus.args ++ (optional config.dbus.filter "--filter");'
      # bubblewrap.uid/gid: the uid/gid the app sees inside its user namespace
      # (bwrap --uid/--gid, which need a definite --unshare-user).
      substituteInPlace modules/bubblewrap.nix --replace-fail \
        '    dieWithParent = mkOption {' \
        '    uid = mkOption { default = null; type = types.nullOr types.int; description = "UID inside the sandbox (bwrap --uid)."; };
    gid = mkOption { default = null; type = types.nullOr types.int; description = "GID inside the sandbox (bwrap --gid)."; };
    dieWithParent = mkOption {'
      substituteInPlace modules/launch.nix --replace-fail \
        '    "--unshare-user-try"' \
        '    "--unshare-user-try"
    (optionals (config.bubblewrap.uid != null) [ "--unshare-user" "--uid" (toString config.bubblewrap.uid) "--gid" (toString config.bubblewrap.gid) ])'
      # Mount tmpfs entries BEFORE the binds (upstream mounts them after), so a
      # bind under a tmpfs path — $PWD under /tmp, /tmp/.X11-unix, anything under a
      # tmpfs $HOME — stays visible instead of being hidden by it.
      sed -i -e '/^    tmpfs$/d' -e 's/^    bindPaths$/    tmpfs\n    bindPaths/' modules/launch.nix
      [ "$(grep -c '^    tmpfs$' modules/launch.nix)" = 1 ] \
        && grep -A1 '^    tmpfs$' modules/launch.nix | grep -q '^    bindPaths$' \
        || { echo "nixpak launch.nix tmpfs reorder did not apply" >&2; exit 1; }
    '';
  };
  mkNixPak = (import "${patchedNixpak}/modules") { inherit lib pkgs; };
  bindPath = import ../paths.nix { inherit lib; };
in
let
  # The app's sandbox as a nixpak module, without its entry point: this app's
  # own wrapper below, or one member of a persistent group's shared sandbox
  # (nixpak-group.nix), which imports every member's.
  appModule =
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
        # x11Forward reuses the existing x11 capability (binds /tmp/.X11-unix, no
        # XAUTHORITY — nixpak's sockets.x11 handler DOES read XAUTHORITY and panics
        # when unset, which is why we go through the capability, not that socket).
        ++ [
          (import ../capabilities-nixpak.nix (
            { inherit lib; } // lib.optionalAttrs (gpuDevices != null) { inherit gpuDevices; }
          ) (appCfg.capabilities // { x11 = appCfg.capabilities.x11 || x11Forward; }))
        ]
        ++ cfg.sandbox.nixpakModules;

      # (X11 forward: the socket is bound via the x11 capability above, DISPLAY comes
      # from gui.nix's envOr "DISPLAY" ":0", and auth from the launcher's xhost.)
      bubblewrap.network = lib.mkOverride 999 false;
      bubblewrap.env = appCfg.environment;

      bubblewrap.uid = lib.mkIf (identity != null) identity.uid;
      bubblewrap.gid = lib.mkIf (identity != null) identity.gid;

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
        # extra binds. For a dedicated uid, a home-relative extraBind means "share
        # jrt's ~/<p> into this app" — and we bind it at the APP's OWN ~/<p> (a [src
        # dst] pair: jrt's path → app's home path), so e.g. extraBinds=["Downloads"]
        # makes the app's default ~/Downloads transparently BE jrt's ~/Downloads
        # (host-visible, no download-dir pref to change). The launcher ACLs the jrt-side
        # source (systemd.nix). Same-uid apps and absolute/$PWD paths bind as-is.
        #
        # appearAsUser (identity): $HOME is the user's home path, which the runScript
        # has made the app's home, so jrt's real data comes from its stage
        # (sharedHome), and the app's previous home path gets the same view: its
        # home first, then each shared bind again under it. Only for an app that
        # keeps data: an ephemeral one (no storage entries, e.g. the browsers with
        # a tmpfs home) must not get its on-disk home, writable and kept across
        # launches, at the old path.
        ++ lib.optional (identity != null && storage.entries != [ ]) [
          sloth.homeDir
          identity.oldHome
        ]
        ++ (lib.concatMap (
          p:
          if bindPath.isAbsolute p then
            if identity != null && lib.hasPrefix "${identity.home}/" p then
              [
                [
                  "${sharedHome}/${lib.removePrefix "${identity.home}/" p}"
                  p
                ]
              ]
            else
              [ p ]
          else if bindPath.isPwdRelative p then
            [ (sloth.concat' (sloth.env "PWD") "/${p}") ]
          else if sharedHome != null then
            [
              [
                "${sharedHome}/${p}"
                (sloth.concat' sloth.homeDir "/${p}")
              ]
            ]
            ++ lib.optional (identity != null) [
              "${sharedHome}/${p}"
              "${identity.oldHome}/${p}"
            ]
          else
            [ (sloth.concat' sloth.homeDir "/${p}") ]
        ) cfg.sandbox.extraBinds)
        # Per-app shared downloads: jrt's ~/Downloads/<app> → the app's ~/Downloads.
        # The launcher ACLs the jrt-side subdir + tmpfiles creates it (systemd.nix).
        ++ lib.optional (sharedDownloads != null) [
          "${sharedHome}/Downloads/${sharedDownloads}"
          (sloth.concat' sloth.homeDir "/Downloads")
        ]
        ++ lib.optional (sharedDownloads != null && identity != null) [
          "${sharedHome}/Downloads/${sharedDownloads}"
          "${identity.oldHome}/Downloads"
        ]
        # Cross-uid doc-portal identity bind (dedicated). Soft (--bind-try): the
        # runScript only relays it when jrt actually has a doc portal running.
        ++ lib.optional (docBind != null) docBind
        ++ lib.optional (brokerSocketName != null) [
          (sloth.concat' sloth.runtimeDir "/${brokerSocketName}")
          "/run/sbx/broker.sock"
        ]
        ++ lib.optional (pulseSocketName != null && appCfg.capabilities.audio) [
          (sloth.concat' sloth.runtimeDir "/${pulseSocketName}")
          (sloth.concat' sloth.runtimeDir "/pulse/native")
        ];
      # Read-only extra binds (same-uid apps only: systemd.nix refuses them for
      # a dedicated uid, which would need jrt's data ACL'd to it).
      bubblewrap.bind.ro = map (
        p:
        if bindPath.isAbsolute p then
          p
        else if bindPath.isPwdRelative p then
          sloth.concat' (sloth.env "PWD") "/${p}"
        else
          sloth.concat' sloth.homeDir "/${p}"
      ) (cfg.sandbox.extraBindsReadOnly or [ ]);
      bubblewrap.sockets.pulse = lib.mkIf (pulseSocketName != null) (lib.mkForce false);
    };

  built = mkNixPak {
    config = {
      imports = [ appModule ];
      app.package = cfg.package;
      app.binPath = "bin/${appCfg.packageName}";
      # Dedicated apps: run the inner proxy transparent and let the jrt-side bridge
      # be the (single) filter. Same-uid apps keep the inner filter (default true).
      dbus.filter = !transparentDbus;
    };
  };
in
{
  inherit appModule mkNixPak;
  package = built.config.env;
  # nixpak's generated .flatpak-info (Application name = the app-id, session-bus
  # policy). The systemd backend binds this onto the cross-uid bridge's /proc/root
  # so the portal identifies the dedicated app as sandboxed → hands out doc:// paths.
  flatpakInfoFile = built.config.flatpak.infoFile;
  # The flatpak app-id — used to scope the cross-uid doc-portal bind to this app's
  # by-app/<appId> subtree instead of the whole doc FUSE.
  appId = built.config.flatpak.appId;
  # Whether the sandbox gets a Wayland socket (gui.nix / capabilities.wayland).
  # The backends then hand it a wp_security_context_v1 socket, never the raw one.
  usesWayland = built.config.bubblewrap.sockets.wayland;
  # nixpak's inner launcher script; its env rewrites absolute Exec=/D-Bus paths
  # in share/ to point here (see the Wayland wrapper in nixpak.nix).
  script = built.config.script;
  # The app's session-bus filter policies (--talk/--own/--call/--broadcast). With
  # the inner proxy transparent (transparentDbus), the jrt-side bridge applies these
  # as its --filter, so the filter lives on the trusted uid.
  dbusArgs = built.config.dbus.args;
}
