#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [[ "${CUSTOM_VXLAN_PORT}" == "true" ]]; then
    VXLAN_PORT=9789
else
    VXLAN_PORT=null
fi

cat >> "${SHARED_DIR}/manifest_cluster-network-03-config.yml" << EOF
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  creationTimestamp: null
  name: cluster
spec:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
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
