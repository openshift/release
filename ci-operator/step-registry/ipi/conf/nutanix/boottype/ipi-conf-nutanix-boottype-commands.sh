#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

PATCH="${SHARED_DIR}/install-config-patch-boottype.yaml"
cat > "${PATCH}" << EOF
platform:
  nutanix:
    defaultMachinePlatform:
      bootType: ${BOOTTYPE}
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
echo "Updated bootType in '${CONFIG}'."

echo "The updated bootType:"
yq-go r "${CONFIG}" platform.nutanix.defaultMachinePlatform.bootType
