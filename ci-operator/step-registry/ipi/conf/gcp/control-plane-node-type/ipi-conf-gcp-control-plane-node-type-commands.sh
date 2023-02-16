#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

PATCH="${SHARED_DIR}/node_type.yaml.patch"
cat > "${PATCH}" << EOF
controlPlane:
  platform:
    gcp:
      type: ${CONTROL_PLANE_NODE_TYPE}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
yq-go r "${CONFIG}" controlPlane

rm "${PATCH}"
