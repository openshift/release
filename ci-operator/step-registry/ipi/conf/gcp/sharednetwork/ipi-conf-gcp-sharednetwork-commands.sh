#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH=/tmp/install-config-sharednetwork.yaml.patch

cat > "${PATCH}" << EOF
platform:
  gcp:
    network: do-not-delete-shared-network
    controlPlaneSubnet: do-not-delete-shared-master-subnet
    computeSubnet: do-not-delete-shared-worker-subnet
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
