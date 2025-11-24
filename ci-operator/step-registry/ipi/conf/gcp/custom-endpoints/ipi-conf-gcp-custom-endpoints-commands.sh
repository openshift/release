#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ ! -f "${SHARED_DIR}/gcp_custom_endpoint" ]; then
  echo "$(date -u --rfc-3339=seconds) - '${SHARED_DIR}/gcp_custom_endpoint' not found, nothing to do." && exit 0
fi
gcp_custom_endpoint=$(< "${SHARED_DIR}/gcp_custom_endpoint")

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/custom_endpoints.yaml.patch"
cat >> "${PATCH}" << EOF
platform:
  gcp:
    endpoint:
      name: ${gcp_custom_endpoint}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
yq-go r "${CONFIG}" platform
rm "${PATCH}"
