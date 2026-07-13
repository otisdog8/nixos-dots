# NetworkManager + firewall + captive-browser. See ./DNS.md for the rollout.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Sandboxed ungoogled-chromium (tmpfs homedir, no persistence) if the
  # apps module enabled it; otherwise the plain package as a fallback.
  cbBrowserPkg =
    config.modules.apps.ungoogled-chromium.finalPackage or pkgs.ungoogled-chromium;
in
{
  networking.useDHCP = lib.mkDefault true;

  networking.networkmanager = {
    enable = true;
    wifi.scanRandMacAddress = false;
  };

  networking.firewall = {
    enable = lib.mkDefault true;
    # The tailnet is our administrative network (k3s/NFS/SSH all ride it),
    # so trust it wholesale rather than enumerating per-service ports.
    trustedInterfaces = [ "tailscale0" ];
    # Loose to match the hardening sysctl (rp_filter=2 + src_valid_mark=1);
    # required for k3s/Cilium asymmetric routing.
    checkReversePath = "loose";
  };

  # captive-browser: SOCKS5 + sandboxed ungoogled-chromium for portal auth.
  # ALREADY SANDBOXED: cbBrowserPkg is ungoogled-chromium's framework finalPackage
  # (now a dedicated-uid systemd sandbox with a tmpfs home), so portal auth runs the
  # contained browser, not a raw one — the `or pkgs.ungoogled-chromium` fallback only
  # bites on a host that has captive-browser but not the app enabled. TEST after the
  # dedicated-uid switch: the launcher captures a CURATED env, so confirm the
  # --user-data-dir / --proxy-server=socks5://$PROXY flags still reach the inner
  # browser and a real captive portal loads (the SOCKS proxy is localhost, shared
  # netns, so it should).
  # bindInterface=false lets the upstream default dhcp-dns query every
  # device, so we don't have to hardcode wlan0/wlp3s0 per host.
  programs.captive-browser = {
    bindInterface = false;
    interface = "auto"; # unused with bindInterface=false; satisfies types.str
    browser = lib.concatStringsSep " " [
      ''env XDG_CONFIG_HOME="$PREV_CONFIG_HOME"''
      "${cbBrowserPkg}/bin/chromium"
      "--user-data-dir=\${XDG_DATA_HOME:-$HOME/.local/share}/chromium-captive"
      ''--proxy-server="socks5://$PROXY"''
      ''--host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE localhost"''
      "--no-first-run"
      "--new-window"
      "--incognito"
      "-no-default-browser-check"
      # Plain HTTP so portals can intercept; cache.nixos.org because some
      # portals resolve example.com to 127.0.0.1.
      "http://cache.nixos.org/"
    ];
  };

  # Persistence for networking
  environment.persistence."/persist" = {
    directories = [
      "/etc/NetworkManager/system-connections"
    ];
  };
}
