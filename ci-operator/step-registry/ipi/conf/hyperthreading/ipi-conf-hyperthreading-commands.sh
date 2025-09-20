#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"


PATCH=$(mktemp)

cat > "${PATCH}" << EOF
controlPlane:
  hyperthreading: ${CONTROL_PLANE_NODE_HYPERTHREADING}
compute:
- hyperthreading: ${COMPUTE_NODE_HYPERTHREADING}
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"

cat $PATCH
