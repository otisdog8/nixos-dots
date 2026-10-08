# The guest's network: virtio-net backed by passt in its own unit. passt makes
# every outbound connection from that unit, so the unit's cgroup IP filter
# (lib/netpolicy.nix, with its slice's: the host's and LAN's public addresses)
# — and, with a dedicated uid, owner-matched firewall rules (`portFilter`) —
# apply to all of the guest's traffic. No inbound forwarding, no route to the
# host's loopback (--no-map-gw: the gateway address is the real router, not
# the host). passt can't filter destinations itself, so the host's other
# addresses are only kept out by those filters.
{
  lib,
  pkgs,
  passt,
}:
rec {
  # TEST-NET-1, never a real host: the guest's resolver when DNS is forwarded
  # to the host's resolved (allowNames, which sbx-dnsallow watches there).
  dnsForward = "192.0.2.53";

  dnsArgs =
    { forwardToResolved, dns }:
    if forwardToResolved then
      "--dns ${dnsForward} --dns-forward ${dnsForward} --dns-host 127.0.0.53"
    else
      lib.concatMapStringsSep " " (d: "--dns ${lib.escapeShellArg d}") dns;

  # `prelude`: shell run first (sets whatever `socket` refers to).
  script =
    {
      name,
      prelude ? "",
      socket,
      forwardToResolved,
      dns,
    }:
    pkgs.writeShellScript name ''
      set -euo pipefail
      ${prelude}
      exec ${passt}/bin/passt --foreground --quiet --vhost-user \
        --socket "${socket}" \
        -t none -u none --no-map-gw \
        ${dnsArgs { inherit forwardToResolved dns; }}
    '';

  # serviceConfig for the passt unit, minus ExecStart. `policy`: the result of
  # netpolicy.lower.
  serviceConfig =
    {
      user,
      group,
      policy,
      readWritePaths,
    }:
    lib.optionalAttrs (policy.slice != null) { Slice = policy.slice; }
    // {
      User = user;
      Group = group;
      IPAddressAllow = policy.ipAddressAllow;
      IPAddressDeny = policy.ipAddressDeny;
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = readWritePaths;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
      ];
      UMask = "0077";
      LimitCORE = 0;
    };

  # Port limits the cgroup IP filter can't express (it matches addresses only).
  # The addresses must also be in the unit's IPAddressAllow; these rules then
  # reject everything to them except the listed TCP ports. Matched on the passt
  # unit's uid, which must be dedicated to it: an owner match on a shared uid
  # (the desktop user) would filter that user's own traffic. (A cgroup match
  # can't be used: iptables and nft resolve the path when the rule loads, before
  # the unit's cgroup exists.)
  #
  # rules: [ { addr = "100.64.0.1"; ports = [ 443 ]; } ]
  # Returns { start; stop; } for networking.firewall.extraCommands /
  # extraStopCommands (the iptables firewall).
  portFilter =
    { chain, uid, rules }:
    let
      ipt = "iptables -w";
      ruleLines = lib.concatMapStrings (r: ''
        ${ipt} -A ${chain} -d ${r.addr} -p tcp -m multiport --dports ${
          lib.concatMapStringsSep "," toString r.ports
        } -j RETURN
        ${ipt} -A ${chain} -d ${r.addr} -j REJECT
      '') rules;
      detach = ''
        ${ipt} -D OUTPUT -m owner --uid-owner ${uid} -j ${chain} 2>/dev/null || true
        ${ipt} -F ${chain} 2>/dev/null || true
        ${ipt} -X ${chain} 2>/dev/null || true
      '';
    in
    {
      start = lib.optionalString (rules != [ ]) (
        detach
        + ''
          ${ipt} -N ${chain}
          ${ruleLines}
          ${ipt} -I OUTPUT -m owner --uid-owner ${uid} -j ${chain}
        ''
      );
      stop = lib.optionalString (rules != [ ]) detach;
    };
}
