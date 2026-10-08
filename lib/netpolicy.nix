# Network policy (app.capabilities.networkPolicy / modules.apps.<n>.sandbox.network)
# → systemd's cgroup IP filter (IPAddressAllow= / IPAddressDeny=).
#
# systemd's rule: an address matching IPAddressAllow= is allowed, else one
# matching IPAddressDeny= is denied, else allowed. So `allow` entries are
# exceptions to every block below, and `deny` entries add blocks.
#
# The static ranges can't name the host's own public addresses or its LAN's
# global prefixes (IPv6 above all: the router hands them out, and they change).
# Units in the restricted modes therefore also run in `slice`, whose
# IPAddressDeny= sbx-netlocal (modules/system/sandbox-dnsallow.nix) keeps set to
# exactly those, as they come and go. systemd merges a slice's lists into its
# members', so the same rule holds: a unit's own allow entries still win.
{ lib }:
rec {
  # Ranges that are never the public internet: "this network", RFC 1918, CGNAT
  # (including the tailnet), IETF protocol assignments (PCP/TURN anycast, DS-Lite),
  # reserved and limited broadcast; ULA and the old site-local; and those IPv4
  # ranges again behind the NAT64 well-known prefix (a NAT64 gateway on the LAN
  # would otherwise translate 64:ff9b::192.168.1.1 to the LAN).
  localRanges = [
    "0.0.0.0/8"
    "10.0.0.0/8"
    "100.64.0.0/10"
    "172.16.0.0/12"
    "192.0.0.0/24"
    "192.168.0.0/16"
    "240.0.0.0/4"
    "fc00::/7"
    "fec0::/10"
    "64:ff9b::/104"
    "64:ff9b::a00:0/104"
    "64:ff9b::6440:0/106"
    "64:ff9b::7f00:0/104"
    "64:ff9b::a9fe:0/112"
    "64:ff9b::ac10:0/108"
    "64:ff9b::c000:0/120"
    "64:ff9b::c0a8:0/112"
  ];

  # Everything that isn't the public internet, statically: the host's loopback,
  # link-local, multicast and localRanges. (The host's and LAN's public
  # addresses: `slice`.)
  local = [
    "localhost"
    "link-local"
    "multicast"
  ]
  ++ localRanges;

  # `local` as plain CIDRs (systemd's names expanded), for the services that
  # match addresses themselves (sbx-dnsallow, sbx-netlocal).
  localCidrs = [
    "127.0.0.0/8"
    "::1/128"
    "169.254.0.0/16"
    "fe80::/10"
    "224.0.0.0/4"
    "ff00::/8"
  ]
  ++ localRanges;

  # The slice every unit in a restricted mode runs in (system.slice's child, so
  # system-wide settings on system.slice still apply). Defined, fail-closed until
  # sbx-netlocal has filled it in, by modules/system/sandbox-dnsallow.nix.
  slice = "system-sandboxnet.slice";

  # policy: { mode, allow, deny, allowDns }; backendDefault: the mode "default"
  # resolves to; dns: the resolvers the app uses (for a container, the host's,
  # usually on loopback), kept reachable in the restricted modes when allowDns.
  # Returns { mode; ipAddressAllow; ipAddressDeny; names; slice; }: `names`
  # (allowNames, in the restricted modes) are opened at run time as they
  # resolve, by sbx-dnsallow (modules/system/sandbox-dnsallow.nix); `slice` is
  # the unit's Slice= (null: leave it in system.slice).
  lower =
    {
      policy,
      backendDefault,
      dns ? [ ],
    }:
    let
      mode = if policy.mode == "default" then backendDefault else policy.mode;
      deny =
        {
          open = [ ];
          internet = local;
          allowlist = [ "any" ];
        }
        .${mode};
      allow = policy.allow ++ lib.optionals (mode != "open" && policy.allowDns) dns;
    in
    {
      inherit mode;
      names = lib.optionals (mode != "open") (policy.allowNames or [ ]);
      ipAddressAllow = lib.unique allow;
      ipAddressDeny = lib.unique (deny ++ policy.deny);
      slice = if mode == "open" then null else slice;
    };
}
