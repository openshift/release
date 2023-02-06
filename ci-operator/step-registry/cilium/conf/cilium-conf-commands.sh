#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cilium_olm_rev=1a0e3b6b53f4a280c37e8ce95c87a12709ad9ba0
cilium_version=1.11.0-rc1

cat > "${SHARED_DIR}/manifest_cluster-network-03-config.yml" << EOF
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  networkType: Cilium
  serviceNetwork:
  - 172.30.0.0/16
EOF

# Include all Cilium OLM manifest from https://github.com/cilium/cilium-olm/tree/${cilium_olm_rev}/manifests/cilium.v${cilium_version}

curl --silent --location --fail --show-error "https://github.com/cilium/cilium-olm/archive/${cilium_olm_rev}.tar.gz" --output /tmp/cilium-olm.tgz
tar -C /tmp -xf /tmp/cilium-olm.tgz

cd "/tmp/cilium-olm-${cilium_olm_rev}/manifests/cilium.v${cilium_version}"

cat > "cluster-network-07-cilium-ciliumconfig.yaml" << EOF
apiVersion: cilium.io/v1alpha1
kind: CiliumConfig
metadata:
  name: cilium
  namespace: cilium
spec:
  debug:
    enabled: true
  k8s:
    requireIPv4PodCIDR: true
  logSystemLoad: true
  bpf:
    preallocateMaps: true
  etcd:
    leaseTTL: 30s
  ipv4:
    enabled: true
  ipv6:
    enabled: true
  identityChangeGracePeriod: 0s
  ipam:
    mode: "cluster-pool"
  endpointRoutes: {enabled: true}
  kubeProxyReplacement: "disabled"
  clusterHealthPort: 9940
  tunnelPort: 4789
  cni:
    binPath: "/var/lib/cni/bin"
    confPath: "/var/run/multus/cni/net.d"
    chainingMode: portMap
  prometheus:
    serviceMonitor: {enabled: false}
  hubble:
    tls: {enabled: false}
EOF

for manifest in *.yaml ; do
  cp "${manifest}" "${SHARED_DIR}/manifest_${manifest}"
done

# use public image for the operator because registry.connect.redhat.com requires pull secrets
sed -i 's|image:\ registry.connect.redhat.com/isovalent/|image:\ quay.io/cilium/|g' "${SHARED_DIR}/manifest_cluster-network-06-cilium-00002-cilium-olm-deployment.yaml"
