#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [[ "${CUSTOM_VXLAN_PORT}" == "true" ]]; then
    VXLAN_PORT=9789
else
    VXLAN_PORT=null
fi

CLUSTER_NETWORK_CIDR=${CLUSTER_NETWORK_CIDR:-10.128.0.0/14}
CLUSTER_NETWORK_HOST_PREFIX=${CLUSTER_NETWORK_HOST_PREFIX:-23}

cat >> "${SHARED_DIR}/manifest_cluster-network-03-config.yml" << EOF
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  creationTimestamp: null
  name: cluster
spec:
  clusterNetwork:
  - cidr: ${CLUSTER_NETWORK_CIDR}
    hostPrefix: ${CLUSTER_NETWORK_HOST_PREFIX}
  externalIP:
    policy: {}
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
  defaultNetwork:
    type: OVNKubernetes
    ovnKubernetesConfig:
      hybridOverlayConfig:
        hybridOverlayVXLANPort: ${VXLAN_PORT}
        hybridClusterNetwork:
        - cidr: 10.132.0.0/14
          hostPrefix: 23
EOF
