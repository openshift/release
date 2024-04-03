#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ "$MASQ_TEST" == "ipv4" ]; then
cat >> "${SHARED_DIR}/cluster-network-03-config.yml" << EOF
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  defaultNetwork:
    ovnKubernetesConfig:
      gatewayConfig:
        ipv4:
          internalMasqueradeSubnet: $MASQ_SUBNET_IPV4
EOF
fi

if [ "$MASQ_TEST" == "ipv6" ]; then
cat >> "manifests/cluster-network-03-config.yml" << EOF
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  defaultNetwork:
    ovnKubernetesConfig:
      gatewayConfig:
        ipv6:
          internalMasqueradeSubnet: $MASQ_SUBNET_IPV6
EOF
fi

if [ "$MASQ_TEST" == "dual" ]; then
cat >> "manifests/cluster-network-03-config.yml" << EOF
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  defaultNetwork:
    ovnKubernetesConfig:
      gatewayConfig:
        ipv4:
          internalMasqueradeSubnet: $MASQ_SUBNET_IPV4
        ipv6:
          internalMasqueradeSubnet: $MASQ_SUBNET_IPV6
EOF
fi

cat "${SHARED_DIR}/cluster-network-03-config.yml"
