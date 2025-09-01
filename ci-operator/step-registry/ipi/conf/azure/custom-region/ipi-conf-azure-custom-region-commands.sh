#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/custom-region.yaml.patch"

REGION="${CUSTOM_AZURE_REGION}"
if [[ -z "${CUSTOM_AZURE_REGION}" ]]; then
    REGION="${LEASED_RESOURCE}"
fi

cat > "${PATCH}" << EOF
platform:
 azure:
   region: ${REGION}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  rm "${PATCH}"
