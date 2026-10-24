# Encrypted DNS stack. See ./DNS.md for the architecture and rollout.
#
# Stub:      systemd-resolved on 127.0.0.53:53 (only entry in resolv.conf)
# Upstream:  dnscrypt-proxy on 127.0.0.1:53 (DoH / DoH3 only — every
#            upstream is a static stamp with the IP baked in, so we never
#            do a bootstrap DNS lookup on the hot path)
# Split-DNS: Tailscale pushes *.ts.net + tailnet rules to resolved via D-Bus
# DHCP DNS:  NetworkManager pushes NOTHING to resolved (dns=none +
#            systemd-resolved=false), so 127.0.0.1 is the only resolver
# Captive:   handled by `programs.captive-browser` in networking.nix (it
#            reads the DHCP server from nmcli and resolves via it directly)
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
    # dns-rooty-dev-cf = "sdns://AgAAAAAAAAAAETE3Mi42Ny4xODQuOTY6NDQzAA1kbnMucm9vdHkuZGV2Ci9kbnMtcXVlcnk";
    #dns-rooty-dev-origin = "sdns://AgAAAAAAAAAAETc0LjIwOC40NS4xODE6NDQzAA1kbnMucm9vdHkuZGV2Ci9kbnMtcXVlcnk";
  };

  # Runtime DNS control — no nixos-rebuild needed, and no full restart.
  # `resolvectl` can't help: it only configures *per-link* scopes, but our
  # resolver is the *global* DNS=127.0.0.1, for which only the global DNSSEC
  # setting applies (systemd #23227) and which is settable only via
  # resolved.conf. resolved.conf is Nix-managed (read-only), so each mode
  # drops a /run override (which beats /etc) and SIGHUPs resolved via
  # `reload`: it re-reads config + flushes caches *without* tearing the unit
  # down, so Tailscale's bus-pushed MagicDNS survives. All overrides revert
  # on reboot or `dns-mode encrypted`.
  #
  #   dns-mode encrypted       dnscrypt + DNSSEC=no (the configured default)
  #   dns-mode plain <ip>      global DNS -> <ip> plaintext, bypass dnscrypt, DNSSEC=no
  #   dns-mode validated <ip>  like plain but turns local DNSSEC validation on
  #   dns-mode dhcp            global DNS -> snapshot of NM's DHCP/VPN-pushed servers, DNSSEC=no
  #   dns-mode dnssec-on       keep dnscrypt, DNSSEC=yes (strict local validation)
  #   dns-mode dnssec-off      keep dnscrypt, DNSSEC=no (same as the default; clears dnssec-on)
  #   dns-mode status          show effective resolver + any active override
  dnsMode = pkgs.writeShellApplication {
    name = "dns-mode";
    runtimeInputs = [
      pkgs.systemd
      pkgs.coreutils
      config.networking.networkmanager.package
    ];
    text = ''
      dropin=/run/systemd/resolved.conf.d/zz-dns-override.conf
      # Mutating modes write /run and reload resolved (root); re-exec under
      # the setuid sudo wrapper so e.g. `dns-mode dhcp` just works (one
      # prompt). `status` stays password-free.
      need_root() {
        if [ "$(id -u)" -ne 0 ]; then
          exec /run/wrappers/bin/sudo "$0" "$@"
        fi
      }
      remove_override() {
        rm -f "$dropin"
        systemctl reload-or-restart systemd-resolved
      }
      # write_override <dns-line> <dnssec> — <dns-line> is a full "DNS=..."
      # line to include ("DNS=9.9.9.9", or "DNS=" to reset the inherited
      # 127.0.0.1), or "" to omit it. <dnssec> is the DNSSEC= value.
      write_override() {
        mkdir -p /run/systemd/resolved.conf.d
        {
          printf '[Resolve]\n'
          if [ -n "$1" ]; then printf '%s\n' "$1"; fi
          printf 'DNSSEC=%s\n' "$2"
        } > "$dropin"
        systemctl reload-or-restart systemd-resolved
      }
      case "''${1:-status}" in
        encrypted)
          need_root "$@"
          remove_override
          echo "encrypted: dnscrypt-proxy (127.0.0.1) + DNSSEC=no (configured default)."
          ;;
        plain)
          need_root "$@"
          server="''${2:-}"
          if [ -z "$server" ]; then
            echo "usage: dns-mode plain <server-ip>" >&2
            exit 1
          fi
          write_override "DNS=$server" "no"
          echo "plain: global DNS -> $server (plaintext, bypasses dnscrypt), DNSSEC=no."
          ;;
        validated)
          need_root "$@"
          server="''${2:-}"
          if [ -z "$server" ]; then
            echo "usage: dns-mode validated <server-ip>" >&2
            exit 1
          fi
          write_override "DNS=$server" "yes"
          echo "validated: global DNS -> $server (plaintext, bypasses dnscrypt), DNSSEC=yes."
          ;;
        dhcp)
          need_root "$@"
          # NM doesn't push DNS to resolved (dns=none, see below), so just
          # clearing the global DNS would leave resolved with no server at
          # all. Instead snapshot the servers NM learned (DHCP/RA/VPN; still
          # in each device's IP config) into the global DNS= line. IPv6
          # link-local servers need their interface ("%ifname", resolved.conf(5)
          # DNS=). `-e no`: don't backslash-escape the colons in IPv6 values.
          servers=""
          dev=""
          while IFS= read -r line; do
            key="''${line%%:*}"
            val="''${line#*:}"
            val="''${val//\\/}" # belt and braces vs. "\:" escaping
            [ -n "$val" ] || continue
            case "$key" in
              GENERAL.DEVICE) dev="$val" ;;
              IP4.DNS*) servers="$servers $val" ;;
              IP6.DNS*)
                case "$val" in
                  fe80:* | FE80:*) servers="$servers $val%$dev" ;;
                  *) servers="$servers $val" ;;
                esac
                ;;
            esac
          done < <(nmcli -t -e no -f GENERAL.DEVICE,IP4.DNS,IP6.DNS device show)
          servers="''${servers# }"
          if [ -z "$servers" ]; then
            echo "dhcp: NetworkManager knows no DHCP/VPN DNS servers; nothing changed." >&2
            exit 1
          fi
          write_override "DNS=$servers" "no"
          echo "dhcp: global DNS -> $servers (DHCP/VPN-pushed, plaintext; snapshot — re-run after roaming), DNSSEC=no."
          ;;
        dnssec-on)
          need_root "$@"
          write_override "" "yes"
          echo "dnssec-on: dnscrypt kept, DNSSEC=yes (strict local validation)."
          ;;
        dnssec-off)
          need_root "$@"
          write_override "" "no"
          echo "dnssec-off: dnscrypt kept, DNSSEC=no (same as the configured default)."
          ;;
        status)
          resolvectl status 2>/dev/null | head -n 14 || true
          if [ -f "$dropin" ]; then
            echo "--- runtime override ACTIVE ---"
            cat "$dropin"
          else
            echo "(no override: encrypted dnscrypt + DNSSEC=no)"
          fi
          ;;
        *)
          echo "usage: dns-mode [encrypted|plain <ip>|validated <ip>|dhcp|dnssec-on|dnssec-off|status]" >&2
          exit 1
          ;;
      esac
    '';
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
    # `dns-mode [encrypted|plain <ip>|validated <ip>|dhcp|dnssec-off|status]`
    # — runtime resolver/DNSSEC control via /run drop-in (self-elevates).
    environment.systemPackages = [ dnsMode ];

    services.resolved = {
      enable = true;
      # Encryption happens at dnscrypt-proxy upstream of resolved, so
      # DNSOverTLS stays off here (resolved → 127.0.0.1 is plaintext).
      settings.Resolve = {
        DNS = "127.0.0.1";
        # "~." makes the global DNS the catch-all for any query that
        # doesn't match a more specific routing domain. Tailscale's
        # "~ts.net" is more specific so MagicDNS split-DNS still wins
        # for *.ts.net.
        #
        # NOTE: "~." here is NOT sufficient to stop per-link DNS leaks.
        # NM adds its own "~." to the default-route connection's link
        # (nm-settings-nmcli(5), ipv4.dns-priority: "the '~.' special
        # wildcard domain, which is added automatically to connections with
        # the default route"), and equally-best routing domains are queried
        # in PARALLEL (systemd-resolved.service(8), "Protocols and Routing").
        # So DHCP-pushed servers would race 127.0.0.1 in cleartext. That's
        # closed below by stopping NM from pushing DNS to resolved at all —
        # don't rely on this line for it.
        Domains = "~.";
        # Fallback DNS disabled. By design FallbackDNS only arms when *no*
        # server is known, and DNS=127.0.0.1 is always set, so it shouldn't
        # fire — but two gotchas make "just leave it unset" wrong: (1) there
        # are reports of it firing despite a configured server (systemd
        # #40183, still present on systemd 260), and (2) *omitting* it does
        # NOT disable it — resolved then uses a COMPILED-IN list incl.
        # Google/Cloudflare, queried plaintext and bypassing dnscrypt.
        #
        # It MUST be an empty STRING, not an empty list. FallbackDNS lives
        # inside the [Resolve] SECTION, and NixOS renders section keys with
        # one `key=elem` line PER list element — so `[ ]` emits ZERO lines
        # (key omitted → compiled-in list active, the exact bug this guards
        # against). `""` renders the literal `FallbackDNS=` that actually
        # turns it off. (transformSettings only list-joins TOP-LEVEL keys,
        # i.e. section names, so it never reaches this nested one.)
        FallbackDNS = "";
        DNSStubListener = "yes";
        DNSOverTLS = "no";
        # Off by default (for now): strict local validation caused too many
        # real-world breakages (proof-less answers from middleboxes/CDNs,
        # networks that mangle DNS) to be worth it as the default. We
        # deliberately skip "allow-downgrade" as a middle ground — it was
        # silently caching feature-level downgrades on transient network
        # blips and getting stuck non-validating until a manual
        # `resolvectl reset-server-features`, i.e. the worst of both.
        # Upstreams still validate (the stamps advertise DNSSEC); re-enable
        # local validation at runtime with `dns-mode dnssec-on` (/run
        # drop-in, no rebuild).
        DNSSEC = "no";
        Cache = "yes";
        CacheFromLocalhost = "yes";
        ReadEtcHosts = "yes";
        MulticastDNS = "no";
        LLMNR = "no";
      };
    };

    networking.nameservers = lib.mkForce [ ];

    # NM must NOT hand any DNS to resolved, so 127.0.0.1 (dnscrypt) is the
    # ONLY resolver. If NM pushes the DHCP servers (LAN gateway + whatever
    # public resolver the router advertises, e.g. 8.8.8.8) onto the link
    # together with its automatic "~." (see the Domains= note above),
    # resolved queries them in parallel with dnscrypt — plaintext,
    # bypassing encryption. 8.8.8.8 also returns proof-less DS answers that
    # trip strict DNSSEC under `dns-mode dnssec-on` (`no-signature` on
    # unsigned names like a CNAME to *.up.railway.app).
    #
    # What does NOT work (the previous attempt here): setting
    # `ipv4.ignore-auto-dns`/`ipv6.ignore-auto-dns` via
    # `networking.networkmanager.connectionConfig`. That renders a
    # [connection] default, and NetworkManager.conf(5) "CONNECTION SECTION"
    # says "Not all properties can be overwritten, only the following
    # properties are supported" — ignore-auto-dns is not on that list, so NM
    # silently ignored it. Per-profile ignore-auto-dns (nmcli / dispatcher)
    # would work but is per-connection state on an impermanent system and
    # racy at activation; NM's dns-priority / "~." juggling only ranks NM's
    # own connections against each other and can't make resolved's GLOBAL
    # server exclusive.
    #
    # What does: NetworkManager.conf(5), [main]:
    #   dns=none             "NetworkManager will not modify resolv.conf.
    #                         This implies rc-manager unmanaged" — resolv.conf
    #                         stays NixOS's stub symlink (resolved.nix).
    #   systemd-resolved=false
    #                        "Additionally, send the connection DNS
    #                         configuration to systemd-resolved. Defaults to
    #                         "true". [...] complementary to the dns setting"
    #                         — i.e. dns=none ALONE still pushes per-link DNS
    #                         to resolved; this key is what actually stops it.
    # mkForce: nixpkgs' resolved.nix sets networkmanager.dns =
    # "systemd-resolved" at normal priority. Explicit "none" also matters
    # because an UNSET dns= auto-selects systemd-resolved when resolv.conf
    # is resolved's stub symlink (NetworkManager.conf(5), dns).
    #
    # NM still learns the DHCP servers — they stay in the device's IP config
    # (`nmcli device show` → IP4.DNS), just unused for system resolution.
    # Things that depend on that keep working:
    #   - programs.captive-browser: its dhcp-dns command is
    #     `nmcli dev show | fgrep IP4.DNS` (nixpkgs captive-browser.nix) and
    #     its SOCKS proxy resolves the portal via that server directly, never
    #     through resolved. (Per-profile ignore-auto-dns would have emptied
    #     IP4.DNS and broken this.)
    #   - `dns-mode dhcp` reads the same IP4.DNS/IP6.DNS (see above).
    # Not affected: Tailscale MagicDNS — tailscaled programs resolved over
    # its own D-Bus API (SetLinkDNS/SetLinkDomains on tailscale0), not via NM.
    # Not affected: systemd-networkd links (VM guests), which talk to
    # resolved directly.
    # Trade-offs: (1) no LAN names via the gateway — add a `~lan-domain`
    # split rule (resolved dnsDelegates) rather than leaning on DHCP DNS.
    # (2) NM VPNs (protonvpn-gui) no longer get their pushed DNS: lookups go
    # 127.0.0.1 → dnscrypt → DoH, which egresses through the tunnel's default
    # route (encrypted, no leak), but Proton's resolver/NetShield is unused;
    # `dns-mode dhcp` or `dns-mode plain 10.2.0.1` while connected if wanted.
    # (3) On a captive portal, system DNS fails until you log in through
    # captive-browser (DoH is blocked; nothing cleartext to fall back on).
    #
    # Verify post-switch: `resolvectl status` → Global "DNS Servers:
    # 127.0.0.1" + "DNS Domain: ~."; wlan/ethernet links with NO "DNS
    # Servers" line and "Current Scopes: none"; tailscale0 still carrying
    # 100.100.100.100 + its ts.net domains. Links configured by the OLD NM
    # keep stale servers until reboot or `sudo resolvectl revert <iface>`.
    networking.networkmanager.dns = lib.mkForce "none";
    networking.networkmanager.settings.main.systemd-resolved = false;

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
