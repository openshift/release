#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_NETWORK_CIDR=${CLUSTER_NETWORK_CIDR:-10.128.0.0/20}
CLUSTER_NETWORK_HOST_PREFIX=${CLUSTER_NETWORK_HOST_PREFIX:-23}
SERVICE_NETWORK_CIDR=${SERVICE_NETWORK_CIDR:-172.30.0.0/16}

echo "default is to update cidr to 20 w/ hostPrefix of 23 so that max nodes num is 8"
echo "\nsee below for actual values used\n--------------------------------\n"

cat >> "${SHARED_DIR}/install-config.yaml" << EOF
networking:
  networkType: OVNKubernetes
  clusterNetwork:
  - cidr: $CLUSTER_NETWORK_CIDR
    hostPrefix: $CLUSTER_NETWORK_HOST_PREFIX
  serviceNetwork:
  - $SERVICE_NETWORK_CIDR
EOF

cat "${SHARED_DIR}/install-config.yaml"
