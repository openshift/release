#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

PATCH="${SHARED_DIR}/confidential_computing.yaml.patch"
cat > "${PATCH}" << EOF
platform:
  gcp:
    defaultMachinePlatform:
      confidentialCompute: ${CONFIDENTIAL_COMPUTE}
      onHostMaintenance: ${ON_HOST_MAINTENANCE}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
yq-go r "${CONFIG}" platform

rm "${PATCH}"
