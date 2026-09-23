#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-patch.yaml"

GCP_BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"

if [[ "${BASE_DOMAIN}" != "${GCP_BASE_DOMAIN}" ]]; then
  cat > "${PATCH}" << EOF
baseDomain: ${BASE_DOMAIN}
platform:
  gcp:
    publicDNSZone: 
      id: ${BASE_DOMAIN_ZONE_NAME}
      project: ${BASE_DOMAIN_ZONE_PROJECT}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  echo "Updated platform.gcp.publicDNSZone in '${CONFIG}'."
fi

echo "(debug)--------------------"
yq-go r "${CONFIG}" baseDomain
echo "(debug)--------------------"
yq-go r "${CONFIG}" platform
echo "(debug)--------------------"
