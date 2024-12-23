# k0s

## Installing
`curl --proto '=https' --tlsv1.2 -sSf https://get.k0s.sh | sudo sh`
`mv /usr/local/bin/k0s /var/lib/k0s/`

## Configuring
Example config for arquitens - change the 100.ip to generalize to another node. Setup for cilium.
```yaml
apiVersion: k0s.k0sproject.io/v1beta1
kind: ClusterConfig
metadata:
  name: k0s
spec:
  api:
    address: 100.126.30.73
    onlyBindToAddress: true
    k0sApiPort: 9443
    port: 6443
    sans:
    - 100.126.30.73
  controllerManager: {}
  extensions:
    helm:
      concurrencyLevel: 5
  installConfig:
    users:
      etcdUser: etcd
      kineUser: kube-apiserver
      konnectivityUser: konnectivity-server
      kubeAPIserverUser: kube-apiserver
      kubeSchedulerUser: kube-scheduler
  konnectivity:
    adminPort: 8133
    agentPort: 8132
  network:
    clusterDomain: cluster.local
    dualStack:
      enabled: false
    kubeProxy:
      iptables:
        minSyncPeriod: 0s
        syncPeriod: 0s
      ipvs:
        minSyncPeriod: 0s
        syncPeriod: 0s
        tcpFinTimeout: 0s
        tcpTimeout: 0s
        udpTimeout: 0s
      metricsBindAddress: 0.0.0.0:10249
      mode: iptables
      nftables:
        minSyncPeriod: 0s
        syncPeriod: 0s
    kuberouter:
      autoMTU: true
      hairpin: Enabled
      metricsPort: 8080
    nodeLocalLoadBalancing:
      enabled: false
      envoyProxy:
        apiServerBindPort: 7443
        konnectivityServerBindPort: 7132
      type: EnvoyProxy
    podCIDR: 10.244.0.0/16
    provider: custom
    serviceCIDR: 10.96.0.0/12
  scheduler: {}
  storage:
    etcd:
      peerAddress: 10.0.0.21
    type: etcd
  telemetry:
    enabled: false
```

Install flux:
`sudo flux bootstrap github --token-auth --owner=uorux --repository=homelab --branch=main --kubeconfig $KUBECONFIG   --components-extra image-reflector-controller,image-automation-controller`



