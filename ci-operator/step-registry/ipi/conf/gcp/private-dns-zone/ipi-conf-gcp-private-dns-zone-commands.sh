#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${PRIVATE_ZONE_PROJECT}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - The cluster's DNS private zone will not be created in a separate project. "
  exit 0
fi

if [[ ! -f "${SHARED_DIR}/cluster-pvtz-zone-name" ]]; then
  echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to get the DNS private zone name, abort. "
  exit 1
fi
private_zone_name="$(< ${SHARED_DIR}/cluster-pvtz-zone-name)"

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-patch.yaml"

cat > "${PATCH}" << EOF
platform:
  gcp:
    privateZone: 
      zone: ${private_zone_name}
      projectID: ${PRIVATE_ZONE_PROJECT}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
echo "Updated platform.gcp.privateZone in '${CONFIG}'."

echo "(debug)--------------------"
yq-go r "${CONFIG}" platform
echo "(debug)--------------------"
