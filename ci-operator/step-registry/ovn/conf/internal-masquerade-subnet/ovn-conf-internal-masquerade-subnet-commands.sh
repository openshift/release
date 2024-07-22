#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

cat >> "${SHARED_DIR}/manifest_cluster-network-03-config.yml" << EOF
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  defaultNetwork:
    ovnKubernetesConfig:
      gatewayConfig:
        ipv4:
          internalMasqueradeSubnet: 100.254.169.0/29
EOF

cat ${SHARED_DIR}/manifest_cluster-network-03-config.yml