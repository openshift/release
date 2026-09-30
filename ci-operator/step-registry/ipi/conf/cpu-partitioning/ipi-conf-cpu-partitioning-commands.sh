#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

PATCH="${SHARED_DIR}/install-config-patch.yaml"
cat > "${PATCH}" << EOF
cpuPartitioningMode: AllNodes
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
echo "Updated cpuPartitioningMode in '${CONFIG}'."

echo "The updated cpuPartitioningMode:"
yq-go r "${CONFIG}" cpuPartitioningMode
