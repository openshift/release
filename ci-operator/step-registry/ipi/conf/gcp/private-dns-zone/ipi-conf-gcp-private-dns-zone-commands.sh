#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-patch.yaml"

CLUSTER_NAME=${NAMESPACE}-${UNIQUE_HASH}
CLUSTER_PVTZ_PROJECT="$(< ${SHARED_DIR}/cluster-pvtz-project)"

cat > "${PATCH}" << EOF
platform:
  gcp:
    privateDNSZone: 
      id: ${CLUSTER_NAME}-private-zone
      project: ${CLUSTER_PVTZ_PROJECT}
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
echo "Updated platform.gcp.privateDNSZone in '${CONFIG}'."

echo "(debug)--------------------"
yq-go r "${CONFIG}" platform
echo "(debug)--------------------"
