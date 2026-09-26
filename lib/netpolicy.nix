# Network policy (app.capabilities.networkPolicy / modules.apps.<n>.sandbox.network)
# → systemd's cgroup IP filter (IPAddressAllow= / IPAddressDeny=).
#
# systemd's rule: an address matching IPAddressAllow= is allowed, else one
# matching IPAddressDeny= is denied, else allowed. So `allow` entries are
# exceptions to every block below, and `deny` entries add blocks.
{ lib }:
rec {
  # Everything that isn't the public internet: the host itself, link-local,
  # multicast, RFC 1918 and ULA ranges, and 100.64/10 (CGNAT, including the
  # tailnet).
  local = [
    "localhost"
    "link-local"
    "multicast"
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "100.64.0.0/10"
    "fc00::/7"
  ];

  # policy: { mode, allow, deny, allowDns }; backendDefault: the mode "default"
  # resolves to; dns: the resolvers the app uses (for a container, the host's,
  # usually on loopback), kept reachable in the restricted modes when allowDns.
  # Returns { mode; ipAddressAllow; ipAddressDeny; names; }: `names` (allowNames,
  # in the restricted modes) are opened at run time as they resolve, by
  # sbx-dnsallow (modules/system/sandbox-dnsallow.nix).
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
    };
}
