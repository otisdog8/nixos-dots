# nginx's sandbox, on top of nixpkgs' unit (services/web-servers/nginx), which
# already runs it as the nginx user with only CAP_NET_BIND_SERVICE and
# CAP_SYS_RESOURCE, a read-only system, no home directories or devices, and a
# syscall denylist. (Its config is in secrets.nix: ACME, recommended settings,
# HTTP/2 off.)
{ ... }:
{
  systemd.services.nginx.serviceConfig = {
    # Every vhost here listens on the tailscale address only, and proxies to
    # loopback or to that address (garage, hermes). So the tailnet and
    # loopback are all it talks to; k8s's ingress arrives masqueraded to its
    # node's tailnet address. Code running inside nginx can't reach the LAN or
    # the internet. (Certificates come from the acme units, not nginx; no OCSP
    # stapling.) A vhost on another address needs its clients' range here.
    IPAddressAllow = [
      "localhost"
      "100.64.0.0/10"
      "fd7a:115c:a1e0::/48"
    ];
    IPAddressDeny = "any";

    # nixpkgs' syscall filter is a denylist ("~@cpu-emulation @debug @keyring
    # @mount @obsolete @privileged @setuid"); an allowlist would leave less of
    # the kernel to an attacker inside nginx. Only logged for now, not
    # enforced: these are the calls nginx makes outside @system-service (each
    # a kernel "audit: type=1326" line). If none show up over a few weeks of
    # normal use, enforce it: SystemCallFilter = lib.mkBefore
    # [ "@system-service" ] (nixpkgs' entries then remove from it) plus
    # SystemCallErrorNumber = "EPERM" (the default kills the worker).
    SystemCallLog = [ "~@system-service" ];

    # The nix daemon's socket (made at boot by nix-daemon.socket).
    InaccessiblePaths = [ "-/nix/var/nix/daemon-socket" ];
  };
}
