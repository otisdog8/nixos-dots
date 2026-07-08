# Recusant media server configuration
{ config, pkgs, ... }:
let
  # recusant's tailnet address (same value as hermes-homelab-recusant.nix).
  # sab/jellyfin are reached through the k8s ingress over the tailnet, so
  # these vhosts bind ONLY the tailscale IP — LAN/WAN get connection-refused
  # at the socket layer. The exact-address listen is also what makes Host
  # routing work here at all: the hermes dashboard vhost listens on
  # tailscaleIp:443 specifically, and nginx only server_name-matches within
  # the exact-address candidate set, so any vhost that should answer on the
  # tailnet must join that socket.
  tailscaleIp = "100.110.239.45";
in
{
  imports = [
    ../../modules/apps/jellyfin.nix
    ../../modules/apps/sabnzbd.nix
  ];

  modules.apps.jellyfin = {
    enable = true;
    openFirewall = true;
  };

  modules.apps.sabnzbd = {
    enable = true;
    openFirewall = true;
  };

  services.nginx.virtualHosts."jellyfin.rooty.dev" = {
    serverAliases = [ "jellyfin.recusant.rooty.dev" ]; # direct tailnet name, matches the wildcard cert
    useACMEHost = "recusant.rooty.dev";
    forceSSL = true;
    listenAddresses = [ tailscaleIp ];
    locations."/" = {
      proxyPass = "http://127.0.0.1:8096";
      proxyWebsockets = true; # needed if you need to use WebSocket
      extraConfig =
        # required when the target is also TLS server with multiple hosts
        "proxy_ssl_server_name on;"
        +
          # required when the server wants to use HTTP Authentication
          "proxy_pass_header Authorization;";
    };
  };

  services.nginx.virtualHosts."sab.rooty.dev" = {
    serverAliases = [ "sab.recusant.rooty.dev" ]; # direct tailnet name, matches the wildcard cert
    useACMEHost = "recusant.rooty.dev";
    forceSSL = true;
    listenAddresses = [ tailscaleIp ];
    locations."/" = {
      proxyPass = "http://127.0.0.1:8080";
      proxyWebsockets = true; # needed if you need to use WebSocket
      extraConfig =
        # required when the target is also TLS server with multiple hosts
        "proxy_ssl_server_name on;"
        +
          # required when the server wants to use HTTP Authentication
          "proxy_pass_header Authorization;";
    };
  };
}
