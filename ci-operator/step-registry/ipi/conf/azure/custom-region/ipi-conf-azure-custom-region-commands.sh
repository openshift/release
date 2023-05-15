#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/custom-region.yaml.patch"

cat > "${PATCH}" << EOF
platform:
 azure:
   region: ${CUSTOM_AZURE_REGION}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  rm "${PATCH}"
