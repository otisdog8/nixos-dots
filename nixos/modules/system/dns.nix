# Encrypted DNS stack. See ./DNS.md for the architecture and rollout.
#
# Stub:      systemd-resolved on 127.0.0.53:53 (only entry in resolv.conf)
# Upstream:  dnscrypt-proxy on 127.0.0.1:53 (DoH / DoH3 only — every
#            upstream is a static stamp with the IP baked in, so we never
#            do a bootstrap DNS lookup on the hot path)
# Split-DNS: Tailscale pushes *.ts.net + tailnet rules to resolved via D-Bus
# Captive:   handled by `programs.captive-browser` in networking.nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.system.dns;

  dnscryptListenAddr = "127.0.0.1";
  dnscryptListenPort = 53;

  # Each stamp embeds an IP, so DoH keeps working when 1.1.1.1/9.9.9.9
  # are blocked at the network level — no bootstrap DNS lookup needed.
  # Stamps for public providers are the canonical ones from
  # https://github.com/DNSCrypt/dnscrypt-resolvers/blob/master/v3/public-resolvers.md
  # (they include TLS cert-pin hashes).
  builtinStaticStamps = {
    # Cloudflare 1.1.1.1 — props 7 = DNSSEC + NoLogs + NoFilter
    cloudflare = "sdns://AgcAAAAAAAAABzEuMS4xLjEAEmRucy5jbG91ZGZsYXJlLmNvbQovZG5zLXF1ZXJ5";
    # Quad9 9.9.9.10 (non-filtering, no-ECS) — props 6 = NoLogs + NoFilter
    quad9 = "sdns://AgYAAAAAAAAACDkuOS45LjEwILAZIHRLu3bJqwU-AeB7fgUORz0g95976kNfr-Q8nSQvE2RuczEwLnF1YWQ5Lm5ldDo0NDMKL2Rucy1xdWVyeQ";
    # ControlD free unfiltered — props 7
    controld-unfiltered = "sdns://AgcAAAAAAAAACjc2Ljc2LjIuMTEAFGZyZWVkbnMuY29udHJvbGQuY29tAy9wMA";
    # AdGuard unfiltered 94.140.14.140 — props 7
    adguard-unfiltered = "sdns://AgcAAAAAAAAADTk0LjE0MC4xNC4xNDAgmjo09yfeubylEAPZzpw5-PJ92cUkKQHCurGkTmNaAhkNOTQuMTQwLjE0LjE0MAovZG5zLXF1ZXJ5";
    # Google 8.8.8.8 — props 5 = DNSSEC + NoFilter (no NoLogs; Google logs).
    # Available for opt-in but kept out of the default `upstreams` list.
    google = "sdns://AgUAAAAAAAAABzguOC44LjggsKKKE4EwvtIbNjGjagI2607EdKSVHowYZtyvD9iPrkkHOC44LjguOAovZG5zLXF1ZXJ5";
    # dns.rooty.dev — two stamps: -cf via Cloudflare anycast,
    # -origin direct to IONOS. Both in rotation, so if one path is
    # blocked the other keeps DoH working.
    dns-rooty-dev-cf = "sdns://AgAAAAAAAAAAETE3Mi42Ny4xODQuOTY6NDQzAA1kbnMucm9vdHkuZGV2Ci9kbnMtcXVlcnk";
    dns-rooty-dev-origin = "sdns://AgAAAAAAAAAAETc0LjIwOC40NS4xODE6NDQzAA1kbnMucm9vdHkuZGV2Ci9kbnMtcXVlcnk";
  };

  customResolverType = lib.types.submodule {
    options.stamp = lib.mkOption {
      type = lib.types.str;
      description = ''
        DNS stamp ("sdns://..."). Embed the resolver's IP so it can be
        reached without prior DNS bootstrap. Generate with
        https://dnscrypt.info/stamps/ or `dnscrypt-proxy -resolve`.
      '';
    };
  };

in
{
  options.modules.system.dns = {
    enable = lib.mkEnableOption "encrypted DNS stack (resolved + dnscrypt-proxy)";

    upstreams = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "cloudflare"
        "quad9"
        "controld-unfiltered"
        "adguard-unfiltered"
        # "google"  # opt-in: works but its stamp says NoLogs=false
        "dns-rooty-dev-cf"
        "dns-rooty-dev-origin"
      ];
      description = ''
        dnscrypt-proxy server_names. Each must have a matching entry in
        `builtinStaticStamps` or `customResolvers` — we don't subscribe
        to the public-resolvers source list, so names from there won't
        resolve without an accompanying stamp.
      '';
    };

    fallbackDns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # Diverse providers/jurisdictions; not all likely blocked at once.
      default = [
        "208.67.222.222" # OpenDNS
        "101.101.101.101" # Quad101 (Taiwan)
        "94.140.14.140" # AdGuard unfiltered
      ];
      description = "Last-resort plain-DNS for systemd-resolved if dnscrypt-proxy is down.";
    };

    bootstrapResolvers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # Deliberately NOT 1.1.1.1 / 9.9.9.9 — those are the IPs most
      # often blocked on hostile networks. Currently unused on the hot
      # path (every stamp embeds an IP) but kept set so it has sane
      # defaults if you ever add a hostname-only stamp or re-enable
      # source-list fetching.
      default = [
        "208.67.222.222:53" # OpenDNS
        "101.101.101.101:53" # Quad101
        "94.140.14.140:53" # AdGuard
        "76.76.2.0:53" # ControlD
      ];
      description = "dnscrypt-proxy bootstrap_resolvers (fallback for hostname lookups).";
    };

    customResolvers = lib.mkOption {
      type = lib.types.attrsOf customResolverType;
      default = { };
      example = lib.literalExpression ''
        {
          home-pi = { stamp = "sdns://..."; };
        }
      '';
      description = ''
        Additional static stamps merged with the built-ins (cloudflare,
        quad9, google, controld-unfiltered, adguard-unfiltered,
        dns-rooty-dev-cf, dns-rooty-dev-origin). Reference them by name
        in `modules.system.dns.upstreams`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.resolved = {
      enable = true;
      # Encryption happens at dnscrypt-proxy upstream of resolved, so
      # DNSOverTLS stays off here (resolved → 127.0.0.1 is plaintext).
      settings.Resolve = {
        DNS = "127.0.0.1";
        # "~." makes the global DNS the catch-all for any query that
        # doesn't match a more specific routing domain. Without it,
        # per-link DNS pushed by NetworkManager from DHCP (i.e. the
        # ISP's resolver) would catch arbitrary queries — that's a
        # leak. Tailscale's "~ts.net" is more specific so MagicDNS
        # split-DNS still wins for *.ts.net.
        Domains = "~.";
        FallbackDNS = lib.concatStringsSep " " cfg.fallbackDns;
        DNSStubListener = "yes";
        DNSOverTLS = "no";
        DNSSEC = "allow-downgrade";
        Cache = "yes";
        CacheFromLocalhost = "yes";
        ReadEtcHosts = "yes";
        MulticastDNS = "no";
        LLMNR = "no";
      };
    };

    # NM hands DNS to resolved instead of fighting over resolv.conf.
    networking.networkmanager.dns = "systemd-resolved";
    networking.nameservers = lib.mkForce [ ];

    # Boot-time race fix: dnscrypt-proxy ships with Type=simple, so a plain
    # After= on it only blocks until fork() — not until 127.0.0.1:53 is
    # bound. dnscrypt-proxy links against coreos/go-systemd and calls
    # SdNotify("READY=1") only after upstream resolvers are probed, so
    # Type=notify is the canonical signal we can hang ordering off of.
    #
    # We can't put After=dnscrypt-proxy on systemd-resolved itself: resolved
    # is part of sysinit.target on NixOS, and dnscrypt-proxy transitively
    # depends on sysinit (via basic→sockets→nix-daemon.socket), so the edge
    # closes the loop and systemd silently *deletes* resolved's start job to
    # break the cycle. resolved still comes up via socket activation later,
    # but by then tailscaled has already inspected the system, found no
    # resolved on D-Bus, and locked itself into "direct /etc/resolv.conf
    # rewrite" mode for the rest of the boot — losing the *.ts.net split-DNS
    # push and any tailnet search domain.
    #
    # Instead, push the dependency the other way: when dnscrypt-proxy reaches
    # READY=1, restart resolved so it forgets any "degraded" marking it
    # accumulated against 127.0.0.1 during the warmup window.
    systemd.services.dnscrypt-proxy.serviceConfig = {
      Type = "notify";
      # sd_notify writes to an AF_UNIX socket; the upstream unit's
      # RestrictAddressFamilies whitelist is INET/INET6 only, so without
      # this the READY=1 syscall is blocked. Append-merges with upstream.
      RestrictAddressFamilies = [ "AF_UNIX" ];
      # `+` runs this one exec with full privileges, bypassing User=/Caps=
      # set on the unit — needed because dnscrypt-proxy runs as its own
      # dynamic user and can't restart system units without polkit.
      ExecStartPost = "+${pkgs.systemd}/bin/systemctl --no-block try-restart systemd-resolved.service";
    };

    # Tailscaled picks its DNS-management mode once at startup and never
    # reconsiders. Order it after resolved so the D-Bus handoff path is the
    # one that gets picked — otherwise it falls back to direct mode and the
    # whole encrypted-DNS + tailnet split-DNS chain is bypassed.
    systemd.services.tailscaled = {
      after = [ "systemd-resolved.service" ];
      wants = [ "systemd-resolved.service" ];
    };

    services.dnscrypt-proxy = {
      enable = true;
      settings = {
        listen_addresses = [ "${dnscryptListenAddr}:${toString dnscryptListenPort}" ];

        ipv6_servers = true;
        block_ipv6 = false;
        require_nolog = true;
        require_nofilter = false;
        require_dnssec = false;

        server_names = cfg.upstreams;

        bootstrap_resolvers = cfg.bootstrapResolvers;
        ignore_system_dns = true;

        cache = true;
        cache_min_ttl = 60;
        cache_max_ttl = 86400;
        cache_neg_min_ttl = 60;
        cache_neg_max_ttl = 600;

        lb_strategy = "p2";
        lb_estimator = true;

        # HTTP/3 where servers advertise Alt-Svc; falls back to H2 silently.
        http3 = true;

        # User entries override built-ins on name collision.
        static = lib.mapAttrs (_n: s: { stamp = s; }) (
          builtinStaticStamps // lib.mapAttrs (_n: v: v.stamp) cfg.customResolvers
        );
      };
    };
  };
}
