# vm backend — the app runs inside a crosvm microVM.
#
# Unlike the container backends this is not chosen by app.defaultBackend: every
# app evaluates it NEXT TO its container backend (lib/apps.nix), and
# modules.apps.<name>.sandbox.mode picks which one the app's command runs. Both
# work on the SAME data, so switching is free.
#
# This file only describes the app as a VM *member* (its storage, binds,
# capabilities, D-Bus policy, and the uid that owns its data) and picks its
# instance (lib/vm/instance.nix, where the VM itself is built and documented):
#   - its own VM (sandbox-vm-<app>, or one per project directory for apps with
#     capabilities.cwd), or
#   - its group's VM, when the app is listed in a modules.sandbox.groups.<g>.apps
#     (sandbox-vm-group-<g>, built once in nixos/modules/system/sandbox-vm.nix
#     from every member's record in modules.sandbox.vm.members).
#
# Not lowered yet (the app still starts, without them): device binds,
# ./-relative binds, whatever raw nixpakModules add beyond gui/xdg/audio/D-Bus,
# variantCommands, and file-descriptor passing over D-Bus (screen capture,
# camera, and portal calls that hand over fds, such as OpenURI's OpenFile).
# File-chooser results do work: they arrive as document-portal paths, which the
# VM sees through its by-app share. Selecting mode = "vm" for an app that uses
# any of the unsupported ones emits a warning listing them.
{
  appName,
  appCfg,
  cfg,
  config,
  lib,
  pkgs,
  inputs,
  storage,
  # The uid/group that owns the app's data and runs the VMM (the user, or
  # app-<name> for a systemd dedicatedUser app).
  principal,
  principalGroup,
  # Package whose share/ provides .desktop entries and icons: the container
  # backend's, whose Exec= lines already name the app's command.
  desktopSource,
  # The container backend's session-bus filter and .flatpak-info (null when the
  # app is unsandboxed): the VM's D-Bus proxy applies the same policy.
  dbusArgs ? null,
  flatpakInfoFile ? null,
}:
let
  paths = import ../paths.nix { inherit lib; };
  variants = import ../variants.nix { inherit lib pkgs; };
  mkInstance = import ../vm/instance.nix { inherit config lib pkgs; };

  username = builtins.head appCfg.defaultUsernames;
  bin = appCfg.packageName;
  caps = appCfg.capabilities;

  # sandbox.vm.nested: inside the guest, the app runs in its nixpak sandbox too.
  # The guest grafts every storage entry onto ~/path, which is the systemd
  # backend's layout (stashAtHome). The guest's host services live outside the
  # runtime dir nixpak binds from, so the wrapper links them in first.
  nested = cfg.sandbox.vm.nested && appCfg.defaultBackend != "none";
  nestedInner = import ./nixpak-pkg.nix {
    inherit
      appCfg
      cfg
      lib
      pkgs
      inputs
      storage
      ;
    stashAtHome = true;
    brokerSocketName = "sbx-broker.sock";
  };
  nestedPkg = pkgs.writeShellScriptBin bin ''
    rt="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    link() { [ -e "$1" ] && ${pkgs.coreutils}/bin/ln -sfn "$1" "$2"; }
    link /run/sbx/broker.sock "$rt/sbx-broker.sock"
    if [ -S /run/sbx/pulse/native ]; then
      ${pkgs.coreutils}/bin/mkdir -p "$rt/pulse"
      link /run/sbx/pulse/native "$rt/pulse/native"
      export PULSE_SERVER="unix:$rt/pulse/native"
    fi
    case "''${WAYLAND_DISPLAY:-}" in
      /*) link "$WAYLAND_DISPLAY" "$rt/sbx-wayland-0" && export WAYLAND_DISPLAY=sbx-wayland-0 ;;
    esac
    exec ${nestedInner.package}/bin/${bin} "$@"
  '';

  # This app as a VM member (the record groups are built from).
  member = {
    inherit
      appName
      bin
      username
      principal
      principalGroup
      caps
      dbusArgs
      flatpakInfoFile
      ;
    package = if nested then nestedPkg else cfg.package;
    entries = storage.entries;
    x11Forward = cfg.sandbox.x11Forward;
    inherit (cfg.sandbox.vm) relays guestBinds guestServices;
    # Home-relative or absolute binds (./-relative ones are dropped with a warning).
    bindReqs =
      lib.optionals caps.gitConfig [
        {
          path = ".gitconfig";
          ro = true;
        }
        {
          path = ".config/git";
          ro = true;
        }
      ]
      ++ map (p: {
        path = p;
        ro = true;
      }) caps.binds.ro
      ++ map (p: {
        path = p;
        ro = false;
      }) (caps.binds.rw ++ cfg.sandbox.extraBinds);
  };

  groups = config.modules.sandbox.groups;
  group = lib.findFirst (g: lib.elem appName groups.${g}.apps) null (lib.attrNames groups);

  instance =
    if group == null then
      mkInstance {
        name = appName;
        members = [ member ];
        perCwd = caps.cwd;
        inherit (cfg.sandbox.vm) persistent memory vcpus;
        network = cfg.sandbox.network;
      }
    else
      config.modules.sandbox.vm.groupInstances.${group};

  launcher = instance.launcherFor member;

  package = pkgs.runCommand "${appName}-sandbox-vm" { } ''
    mkdir -p $out/bin
    ln -s ${launcher} $out/bin/${bin}
    for d in icons pixmaps; do
      if [ -e ${desktopSource}/share/$d ]; then
        mkdir -p $out/share
        ln -s ${desktopSource}/share/$d $out/share/$d
      fi
    done
    for f in ${desktopSource}/share/applications/*.desktop; do
      [ -e "$f" ] || continue
      mkdir -p $out/share/applications
      ${pkgs.gnused}/bin/sed -E -e '${variants.execExpr bin bin}' -e '/^DBusActivatable=/d' \
        "$f" > "$out/share/applications/$(basename "$f")"
    done
  '';

  unsupported =
    lib.optional (caps.gpu && !instance.nvgpu) "gpu"
    ++ lib.optional (caps.wayland && !instance.gui) "wayland"
    ++ lib.optional (caps.x11 && !instance.x11) "x11"
    ++ lib.optional (caps.fido && !instance.fido) "fido"
    ++ lib.optional (caps.binds.dev != [ ]) "device binds"
    ++ lib.optional (caps.dbus.policies != { } && !instance.bus) "D-Bus policies"
    ++ lib.optional (lib.any (b: paths.isPwdRelative b.path) member.bindReqs) "./-relative binds"
    # gui/xdg/audio/D-Bus are carried over; what raw nixpak modules add beyond
    # that (extra binds, env, device nodes) is not.
    ++ lib.optional (
      appCfg.nixpakModules != [ ] || cfg.sandbox.nixpakModules != [ ]
    ) "binds/env/devices from raw nixpakModules"
    ++ lib.optional (appCfg.variantCommands != { }) "variantCommands";
in
{
  inherit package member;
  systemConfig = {
    # The /dev/vhost-vsock device crosvm opens.
    boot.kernelModules = [ "vhost_vsock" ];

    # Every VM-capable app publishes its member record; groups are built from them.
    modules.sandbox.vm.members.${appName} = member;

    # A grouped app's VM (units, polkit) is its group's, defined once for the group.
    systemd.services = lib.optionalAttrs (group == null) instance.services;
    modules.sandbox.units = lib.optionals (group == null) instance.polkitUnits;
    modules.sandbox.unitTemplates = lib.optionals (group == null) instance.polkitTemplates;
    assertions = lib.optionals (group == null) instance.assertions;
    modules.sandbox.broker.sandboxes = lib.optionalAttrs (group == null) {
      ${instance.brokerName} = instance.brokerEntry;
    };

    warnings =
      lib.optional (cfg.sandbox.mode == "vm" && unsupported != [ ])
        "sandbox app '${appName}' runs in a VM, which doesn't provide these yet (they are ignored): ${lib.concatStringsSep ", " unsupported}.";
  };
}
