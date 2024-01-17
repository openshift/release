#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

cilium_olm_rev="main"
cv="$CILIUM_VERSION"

sed -i "s/networkType: .*/networkType: Cilium/" "${SHARED_DIR}/install-config.yaml"

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

# OLD -- Include all Cilium OLM manifest from https://github.com/cilium/cilium-olm/tree/${cilium_olm_rev}/manifests/cilium.v${cv}
# New -- Migrating to new OLM ( https://github.com/isovalent/olm-for-cilium )

OLM_URL="https://github.com/isovalent/olm-for-cilium"

curl --silent --location --fail --show-error "${OLM_URL}/archive/${cilium_olm_rev}.tar.gz" --output /tmp/cilium-olm.tgz
tar -C /tmp -xf /tmp/cilium-olm.tgz

cd "/tmp/olm-for-cilium-${cilium_olm_rev}/manifests/cilium.v${cv}"
# Overwrite the CiliumConfig
cat > cluster-network-07-cilium-ciliumconfig.yaml << EOF
apiVersion: cilium.io/v1alpha1
kind: CiliumConfig
metadata:
  name: cilium
  namespace: cilium
spec:
  cni:
    binPath: /var/lib/cni/bin
    confPath: /var/run/multus/cni/net.d
  endpointRoutes:
    enabled: ${ENDPOINT_ROUTES}
  hubble:
    enabled: ${HUBBLE}
  ipam:
    mode: cluster-pool
    operator:
      clusterPoolIPv4MaskSize: "23"
      clusterPoolIPv4PodCIDRList:
      - 10.128.0.0/14
  kubeProxyReplacement: disabled
  nativeRoutingCIDR: 10.128.0.0/14
  operator:
    prometheus:
      enabled: true
      serviceMonitor:
        enabled: true
  prometheus:
    enabled: true
    serviceMonitor:
      enabled: true
  securityContext:
    privileged: true
  sessionAffinity: true
  clusterHealthPort: 9940
  tunnelPort: 4789
EOF
for manifest in *.yaml ; do
  cp "${manifest}" "${SHARED_DIR}/manifest_${manifest}"
done