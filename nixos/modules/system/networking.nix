# NetworkManager + firewall + captive-browser. See ./DNS.md for the rollout.
{
  config,
  lib,
  ...
}:
let
  cbBrowserPkg = config.modules.apps.captive-browser-chromium.finalPackage;
in
{
  imports = [ ../apps/captive-browser-chromium.nix ];

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

  # captive-browser: SOCKS5 + a purpose-built sandboxed Chromium instance for
  # portal auth. The systemd sandbox launcher intentionally cannot forward cold
  # launch arguments, so chromium-captive has the matching proxy/browser flags
  # baked into its package and this command passes no arguments at all.
  # bindInterface=false lets the upstream default dhcp-dns query every
  # device, so we don't have to hardcode wlan0/wlp3s0 per host.
  programs.captive-browser = {
    bindInterface = false;
    interface = "auto"; # unused with bindInterface=false; satisfies types.str
    # Keep this synchronized with the proxy flag in captive-browser-chromium.nix.
    socks5-addr = "localhost:1666";
    browser = "${cbBrowserPkg}/bin/chromium-captive";
  };

  modules.apps.captive-browser-chromium.enable = config.programs.captive-browser.enable;

  # Persistence for networking
  environment.persistence."/persist" = {
    directories = [
      "/etc/NetworkManager/system-connections"
    ];
  };
}
