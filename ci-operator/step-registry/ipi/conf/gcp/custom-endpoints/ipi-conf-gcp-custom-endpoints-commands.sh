#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

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
      clusterUseOnly: ${CUSTOM_ENDPOINT_FOR_CLUSTER_OPERATORS_ONLY}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
yq-go r "${CONFIG}" platform
rm "${PATCH}"
