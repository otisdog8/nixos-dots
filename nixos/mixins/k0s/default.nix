{
  config,
  hostname,
  inputs,
  lib,
  modulesPath,
  outputs,
  pkgs,
  platform,
  stateVersion,
  username,
  ...
}:

{
  imports = [
     inputs.k0s.nixosModules.default
     ./secrets.nix
  ];

  networking.firewall.allowedTCPPorts = [
    4240 # cluster health checks (cilium-health)
    4244 # Hubble server
    4245 # Hubble Relay
    4250 # Mutual Authentication port
    4251 # Spire Agent health check port (listening on 127.0.0.1 or ::1)
    6060 # cilium-agent pprof server (listening on 127.0.0.1)
    6061 # cilium-operator pprof server (listening on 127.0.0.1)
    6062 # Hubble Relay pprof server (listening on 127.0.0.1)
    9878 # cilium-envoy health listener (listening on 127.0.0.1)
    9879 # cilium-agent health status API (listening on 127.0.0.1 and/or ::1)
    9890 # cilium-agent gops server (listening on 127.0.0.1)
    9891 # operator gops server (listening on 127.0.0.1)
    9893 # Hubble Relay gops server (listening on 127.0.0.1)
    9901 # cilium-envoy Admin API (listening on 127.0.0.1)
    9962 # cilium-agent Prometheus metrics
    9963 # cilium-operator Prometheus metrics
    9964 # cilium-envoy Prometheus metrics
    6443 # k3s: required so that pods can reach the API server (running on port 6443 by default)
    2379 # k3s, etcd clients: required if using a "High Availability Embedded etcd" configuration
    2380 # k3s, etcd peers: required if using a "High Availability Embedded etcd" configuration
  ];

  networking.firewall.allowedUDPPorts = [
    51871 # WireGuard encryption tunnel endpoint
  ];


  environment.systemPackages = with pkgs; [
    inputs.k0s.packages."${pkgs.system}".k0s
    k3s
  ];

  services.k3s = {
    enable = false;
    role = "server";
    extraFlags = [ "--flannel-backend=none"
                   "--disable-network-policy"
                   "--tls-san=100.126.30.73"
                   "--tls-san=100.65.16.13"
                   "--tls-san=100.80.37.112" ];
  };

  networking.firewall.enable = lib.mkForce false;

  services.k0s = {
    package = inputs.k0s.packages."${pkgs.system}".k0s;
    enable = true;
    role = "controller+worker";
    spec.network.provider = "custom";
  };
}
