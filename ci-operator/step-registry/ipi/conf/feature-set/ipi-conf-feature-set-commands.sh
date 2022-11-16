#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

PATCH="${SHARED_DIR}/install-config-patch.yaml"
cat > "${PATCH}" << EOF
featureSet: ${FEATURE_SET}
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
echo "Updated featureSet in '${CONFIG}'."

echo "The updated featureSet:"
yq-go r "${CONFIG}" featureSet
