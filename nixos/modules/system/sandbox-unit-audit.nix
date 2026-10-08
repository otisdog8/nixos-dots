# The sandbox machinery's rule for root code, checked at evaluation: every
# system service it generates (sandbox-*, sandbox-vm-*, sbx-*, agent-vm*,
# op-broker*) that runs as root — no User=, User=root, or any "!" Exec line —
# must be confined: ProtectSystem=strict and an explicit CapabilityBoundingSet
# that isn't an inverted ("~…", everything but) set. Empty is fine: root with no
# capabilities at all. And no unit of it may have a "+" Exec line, which runs
# that command outside all of the unit's confinement.
#
# And a VM's units run as the desktop user only where they must (lib/vm/
# instance.nix, "Security shape": -wl, -bus, -bus-info, -docs-portal, -docs,
# the grants hub); everything else the guest talks to runs as the VM's own uid.
#
# Why: those units act on paths and processes the user (or a sandboxed app)
# controls. The rule they follow (lib/vm/instance.nix, the header): root works
# only on root-owned paths or on objects their owner opened, as the owner
# inside the owner's folders; and each root step is a confined unit of its own.
# This check is the backstop that keeps a new root step from skipping that.
{ config, lib, ... }:
let
  ours = name: builtins.match "(sandbox-|sbx-|agent-vm|op-broker).*" name != null;
  desktopUser = config.modules.sandbox.vm.user;
  vmUnit = name: builtins.match "sandbox-vm-.*" name != null;
  # Exact names, per instance: every instance has its VMM unit (sandbox-vm-<name>,
  # "@" for a per-project one) and a -prep unit next to it. A suffix match would
  # also pass, e.g., -capture-bus or the VMM of an app named "foo-docs".
  instances = lib.concatMap (
    n:
    let
      m = builtins.match "(sandbox-vm-.*)-prep(@?)" n;
    in
    lib.optional (m != null && config.systemd.services ? "${lib.head m}${lib.last m}") m
  ) (lib.attrNames config.systemd.services);
  asUserUnits = lib.concatMap (
    m:
    map (s: "${lib.head m}-${s}${lib.last m}") [
      "wl"
      "bus"
      "bus-info"
      "docs-portal"
      "docs"
      "grants"
    ]
  ) instances;
  asUserOk = name: lib.elem name asUserUnits;

  # Units that can't comply yet, by exact name. Each entry says why and what
  # removes it; delete it as soon as the unit passes.
  exempt = [
    # lib/broker/attach.nix (modules/system/sandbox-broker.nix): the attach
    # helper mounts into other sandboxes' namespaces (setns + move_mount) and
    # runs without ProtectSystem=strict. Remove once it is confined.
    "sbx-attach@"
  ];

  execKeys = [
    "ExecCondition"
    "ExecStartPre"
    "ExecStart"
    "ExecStartPost"
    "ExecReload"
    "ExecStop"
    "ExecStopPost"
  ];
  # An Exec line's prefix characters (systemd.service(5): "@", "-", ":", "+",
  # "!", in any order).
  prefixOf = line: lib.head (builtins.match "([-@:+!]*).*" (toString line));
  execLines = sc: lib.concatMap (k: lib.toList (sc.${k} or [ ])) execKeys;
  capsText = c: if lib.isList c then lib.concatStringsSep " " c else toString c;

  problems =
    name:
    let
      sc = config.systemd.services.${name}.serviceConfig;
      user = sc.User or null;
      lines = execLines sc;
      plus = lib.filter (l: lib.hasInfix "+" (prefixOf l)) lines;
      bang = lib.filter (l: lib.hasInfix "!" (prefixOf l)) lines;
      root = !(sc.DynamicUser or false) && (user == null || user == "root" || user == 0 || user == "0");
      caps = sc.CapabilityBoundingSet or null;
      confined =
        (sc.ProtectSystem or null) == "strict" && caps != null && !(lib.hasPrefix "~" (capsText caps));
    in
    lib.optional (plus != [ ]) "a \"+\" Exec line (${lib.concatStringsSep "; " plus})"
    ++ lib.optional (vmUnit name && user == desktopUser && !asUserOk name) (
      "runs as ${desktopUser}, which only a VM's -wl, -bus, -bus-info, -docs-portal, -docs and grants hub may"
      + " (lib/vm/instance.nix vmUser)"
    )
    ++ lib.optional ((root || bang != [ ]) && !confined) (
      "runs as root${
        lib.optionalString (!root) " (\"!\" Exec lines)"
      } without ProtectSystem=\"strict\" and a "
      + "CapabilityBoundingSet that names what it needs (ProtectSystem = ${
        toString (sc.ProtectSystem or "unset")
      }, CapabilityBoundingSet = ${if caps == null then "unset" else "\"${capsText caps}\""})"
    );

  checked = lib.filter (n: ours n && !(lib.elem n exempt)) (lib.attrNames config.systemd.services);
  violations = lib.concatMap (n: map (p: "  ${n}.service: ${p}") (problems n)) checked;
in
{
  assertions = [
    {
      assertion = violations == [ ];
      message = ''
        sandbox units break the rule for root code (nixos/modules/system/sandbox-unit-audit.nix):
        ${lib.concatStringsSep "\n" violations}
        Run root steps in a unit of their own with core.hardening.rootStep (lib/vm/core/hardening.nix).'';
    }
  ];
  # A stale exemption hides the next regression of that unit.
  warnings =
    let
      stale = lib.filter (n: config.systemd.services ? ${n} && problems n == [ ]) exempt;
    in
    lib.optional (stale != [ ])
      "sandbox-unit-audit.nix: these exempt units comply now; remove them from `exempt`: ${lib.concatStringsSep ", " stale}";
}
